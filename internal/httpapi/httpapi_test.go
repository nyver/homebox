package httpapi_test

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/homebox/homebox/internal/auth"
	"github.com/homebox/homebox/internal/database"
	"github.com/homebox/homebox/internal/httpapi"
	"github.com/homebox/homebox/internal/httpserver"
	"github.com/homebox/homebox/internal/provisioning"
	"github.com/homebox/homebox/internal/securetransport"
	"github.com/homebox/homebox/internal/serveridentity"
)

const testPassword = "correct horse battery staple 42"

type testServer struct {
	baseURL string
	client  *http.Client
	rawLog  *recordingListener
}

func startTestServer(t *testing.T) testServer {
	t.Helper()
	dir := t.TempDir()
	db, err := database.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	identity, err := serveridentity.LoadOrCreate(dir)
	if err != nil {
		t.Fatal(err)
	}
	authService := auth.New(db, 5, 15*time.Minute)
	if _, err := authService.BootstrapAdmin(context.Background(), "admin", testPassword); err != nil {
		t.Fatal(err)
	}
	api := httpapi.New(authService, provisioning.New(db))

	rawListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	recorder := &recordingListener{Listener: rawListener}
	tlsConfig, err := securetransport.BuildTLSConfig(identity)
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: httpserver.New(api)}
	go server.Serve(tls.NewListener(recorder, tlsConfig))
	t.Cleanup(func() { server.Close() })

	clientTLSConfig, err := securetransport.PinnedClientConfig(identity.Fingerprint())
	if err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: clientTLSConfig}}
	return testServer{baseURL: "https://" + rawListener.Addr().String(), client: client, rawLog: recorder}
}

// recordingListener captures every raw byte read from each accepted
// connection *before* TLS decrypts it, so tests can assert that secrets
// never appear on the wire in the clear (spec §38.3).
type recordingListener struct {
	net.Listener
	mu    sync.Mutex
	conns []*recordingConn
}

func (l *recordingListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	rc := &recordingConn{Conn: c}
	l.mu.Lock()
	l.conns = append(l.conns, rc)
	l.mu.Unlock()
	return rc, nil
}

func (l *recordingListener) allRawBytes() []byte {
	l.mu.Lock()
	defer l.mu.Unlock()
	var all []byte
	for _, c := range l.conns {
		c.mu.Lock()
		all = append(all, c.buf.Bytes()...)
		c.mu.Unlock()
	}
	return all
}

type recordingConn struct {
	net.Conn
	mu  sync.Mutex
	buf bytes.Buffer
}

func (c *recordingConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	if n > 0 {
		c.mu.Lock()
		c.buf.Write(p[:n])
		c.mu.Unlock()
	}
	return n, err
}

func (s testServer) do(t *testing.T, method, path string, body any, accessToken string) (*http.Response, map[string]any) {
	t.Helper()
	var reader *bytes.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		reader = bytes.NewReader(b)
	} else {
		reader = bytes.NewReader(nil)
	}
	req, err := http.NewRequest(method, s.baseURL+path, reader)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	if accessToken != "" {
		req.Header.Set("Authorization", "Bearer "+accessToken)
	}
	resp, err := s.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var parsed map[string]any
	if resp.ContentLength != 0 {
		_ = json.NewDecoder(resp.Body).Decode(&parsed)
	}
	return resp, parsed
}

func loginDevice(t *testing.T, s testServer, username, deviceID string) map[string]any {
	t.Helper()
	resp, body := s.do(t, http.MethodPost, "/api/v1/auth/login", map[string]any{
		"username": username,
		"password": testPassword,
		"device": map[string]any{
			"id": deviceID, "name": "Test Device", "platform": "WINDOWS",
			"publicKey": base64.StdEncoding.EncodeToString([]byte("01234567890123456789012345678901")), "keyVersion": 1,
		},
	}, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("login status=%d body=%v", resp.StatusCode, body)
	}
	return body
}

func TestFullLoginDeviceKeyEnvelopeAndRevokeFlow(t *testing.T) {
	s := startTestServer(t)
	trustedDeviceID := "11111111-1111-1111-1111-111111111111"
	newDeviceID := "22222222-2222-2222-2222-222222222222"

	trusted := loginDevice(t, s, "admin", trustedDeviceID)
	trustedToken := trusted["accessToken"].(string)

	newSession := loginDevice(t, s, "admin", newDeviceID)
	newToken := newSession["accessToken"].(string)

	resp, me := s.do(t, http.MethodGet, "/api/v1/users/me", nil, trustedToken)
	if resp.StatusCode != http.StatusOK || me["username"] != "admin" {
		t.Fatalf("users/me status=%d body=%v", resp.StatusCode, me)
	}

	resp, devices := s.do(t, http.MethodGet, "/api/v1/devices", nil, trustedToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("list devices status=%d", resp.StatusCode)
	}
	_ = devices

	resp, _ = s.do(t, http.MethodGet, fmt.Sprintf("/api/v1/devices/%s/key-envelope", newDeviceID), nil, newToken)
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected no envelope yet, status=%d", resp.StatusCode)
	}

	resp, upload := s.do(t, http.MethodPost, fmt.Sprintf("/api/v1/devices/%s/key-envelope", newDeviceID), map[string]any{
		"vaultId": "vault-1", "keyVersion": 1, "ciphertext": base64.StdEncoding.EncodeToString([]byte("wrapped-vault-key")),
	}, trustedToken)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("upload envelope status=%d body=%v", resp.StatusCode, upload)
	}

	resp, envelope := s.do(t, http.MethodGet, fmt.Sprintf("/api/v1/devices/%s/key-envelope", newDeviceID), nil, newToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("download envelope status=%d body=%v", resp.StatusCode, envelope)
	}
	ciphertext, err := base64.StdEncoding.DecodeString(envelope["ciphertext"].(string))
	if err != nil || string(ciphertext) != "wrapped-vault-key" {
		t.Fatalf("unexpected envelope ciphertext: %v (%v)", envelope["ciphertext"], err)
	}

	// A device may not download another device's envelope.
	resp, _ = s.do(t, http.MethodGet, fmt.Sprintf("/api/v1/devices/%s/key-envelope", newDeviceID), nil, trustedToken)
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("cross-device envelope download status=%d, want 403", resp.StatusCode)
	}

	resp, _ = s.do(t, http.MethodDelete, "/api/v1/devices/"+newDeviceID, nil, trustedToken)
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("revoke device status=%d", resp.StatusCode)
	}
	resp, _ = s.do(t, http.MethodGet, "/api/v1/users/me", nil, newToken)
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("revoked device should lose API access, status=%d", resp.StatusCode)
	}
}

func TestLoginRejectsWrongPasswordOverHTTP(t *testing.T) {
	s := startTestServer(t)
	resp, body := s.do(t, http.MethodPost, "/api/v1/auth/login", map[string]any{
		"username": "admin", "password": "totally wrong password",
		"device": map[string]any{
			"id": "33333333-3333-3333-3333-333333333333", "name": "d", "platform": "WINDOWS",
			"publicKey": base64.StdEncoding.EncodeToString([]byte("x")), "keyVersion": 1,
		},
	}, "")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status=%d", resp.StatusCode)
	}
	errBody, _ := body["error"].(map[string]any)
	if errBody["code"] != "AUTH_INVALID_CREDENTIALS" {
		t.Fatalf("error code=%v", errBody["code"])
	}
}

func TestRefreshAndLogout(t *testing.T) {
	s := startTestServer(t)
	session := loginDevice(t, s, "admin", "44444444-4444-4444-4444-444444444444")
	refreshToken := session["refreshToken"].(string)

	resp, refreshed := s.do(t, http.MethodPost, "/api/v1/auth/refresh", map[string]any{"refreshToken": refreshToken}, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("refresh status=%d body=%v", resp.StatusCode, refreshed)
	}
	newRefreshToken := refreshed["refreshToken"].(string)

	resp, _ = s.do(t, http.MethodPost, "/api/v1/auth/logout", map[string]any{"refreshToken": newRefreshToken}, "")
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("logout status=%d", resp.StatusCode)
	}
	resp, _ = s.do(t, http.MethodPost, "/api/v1/auth/refresh", map[string]any{"refreshToken": newRefreshToken}, "")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("refresh after logout status=%d, want 401", resp.StatusCode)
	}
}

// TestPasswordAndTokensNeverAppearOnTheRawWire is the raw-bytes security
// test required by spec §38.3: even though the login request body contains
// the plaintext password in JSON, TLS must ensure it never appears in the
// bytes actually observed on the TCP connection.
func TestPasswordAndTokensNeverAppearOnTheRawWire(t *testing.T) {
	s := startTestServer(t)
	session := loginDevice(t, s, "admin", "55555555-5555-5555-5555-555555555555")
	accessToken := session["accessToken"].(string)
	if resp, _ := s.do(t, http.MethodGet, "/api/v1/users/me", nil, accessToken); resp.StatusCode != http.StatusOK {
		t.Fatalf("expected authenticated request to succeed, status=%d", resp.StatusCode)
	}

	raw := s.rawLog.allRawBytes()
	if len(raw) == 0 {
		t.Fatal("expected to capture raw bytes from the connection")
	}
	if bytes.Contains(raw, []byte(testPassword)) {
		t.Fatal("plaintext password leaked onto the raw wire")
	}
	if bytes.Contains(raw, []byte(accessToken)) {
		t.Fatal("plaintext access token leaked onto the raw wire")
	}
	if strings.Contains(string(raw), "Test Device") {
		t.Fatal("plaintext device name leaked onto the raw wire")
	}
}
