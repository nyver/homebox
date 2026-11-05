package httpapi_test

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"net/http"
	"testing"

	"github.com/homebox/homebox/internal/deviceauth"
)

func signedRecoveryBody(t *testing.T, userID string, bundle []byte, privateKey ed25519.PrivateKey) map[string]any {
	t.Helper()
	statement, err := deviceauth.RecoveryBundleStatement(userID, bundle)
	if err != nil {
		t.Fatal(err)
	}
	return map[string]any{
		"bundle":                   base64.StdEncoding.EncodeToString(bundle),
		"accountIdentityPublicKey": base64.StdEncoding.EncodeToString(privateKey.Public().(ed25519.PublicKey)),
		"signature":                base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, statement)),
	}
}

func TestRecoveryBundleRoundTripAndIdentityBinding(t *testing.T) {
	s := startTestServer(t)
	session := loginDevice(t, s, "admin", "56565656-5656-5656-5656-565656565656")
	token := session["accessToken"].(string)
	userID := session["user"].(map[string]any)["id"].(string)

	if resp, _ := s.get(t, "/api/v1/users/me/recovery", token); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("missing bundle status=%d, want 404", resp.StatusCode)
	}

	_, accountKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	first := []byte("opaque recovery bundle v1")
	if resp, body := s.do(t, http.MethodPut, "/api/v1/users/me/recovery", signedRecoveryBody(t, userID, first, accountKey), token); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("first upload status=%d body=%v", resp.StatusCode, body)
	}
	resp, stored := s.get(t, "/api/v1/users/me/recovery", token)
	if resp.StatusCode != http.StatusOK || stored["bundle"] != base64.StdEncoding.EncodeToString(first) {
		t.Fatalf("stored bundle status=%d body=%v", resp.StatusCode, stored)
	}

	// The same identity may replace its bundle (Recovery Secret rotation).
	second := []byte("opaque recovery bundle v2")
	if resp, body := s.do(t, http.MethodPut, "/api/v1/users/me/recovery", signedRecoveryBody(t, userID, second, accountKey), token); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("rotation status=%d body=%v", resp.StatusCode, body)
	}

	// A session that cannot derive the account identity cannot replace it.
	_, otherKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if resp, body := s.do(t, http.MethodPut, "/api/v1/users/me/recovery", signedRecoveryBody(t, userID, []byte("attacker"), otherKey), token); resp.StatusCode != http.StatusConflict {
		t.Fatalf("foreign identity status=%d body=%v, want 409", resp.StatusCode, body)
	}

	tampered := signedRecoveryBody(t, userID, []byte("tampered"), accountKey)
	tampered["bundle"] = base64.StdEncoding.EncodeToString([]byte("tampered!"))
	if resp, body := s.do(t, http.MethodPut, "/api/v1/users/me/recovery", tampered, token); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("tampered bundle status=%d body=%v, want 400", resp.StatusCode, body)
	}

	resp, stored = s.get(t, "/api/v1/users/me/recovery", token)
	if resp.StatusCode != http.StatusOK || stored["bundle"] != base64.StdEncoding.EncodeToString(second) {
		t.Fatalf("rejected uploads changed the bundle: status=%d body=%v", resp.StatusCode, stored)
	}
}

func TestRecoveryBundleMustMatchTheCertifiedAccountIdentity(t *testing.T) {
	s := startTestServer(t)
	deviceID := "78787878-7878-7878-7878-787878787878"
	session := loginDevice(t, s, "admin", deviceID)
	token := session["accessToken"].(string)
	userID := session["user"].(map[string]any)["id"].(string)

	accountPublicKey, accountKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	statement, err := deviceauth.Statement(userID, deviceID, 1, []byte("01234567890123456789012345678901"))
	if err != nil {
		t.Fatal(err)
	}
	resp, body := s.do(t, http.MethodPost, "/api/v1/devices/"+deviceID+"/key-envelope", map[string]any{
		"vaultId": userID, "keyVersion": 1,
		"ciphertext":               base64.StdEncoding.EncodeToString([]byte("self-approval")),
		"signatureVersion":         deviceauth.SignatureVersion,
		"accountIdentityPublicKey": base64.StdEncoding.EncodeToString(accountPublicKey),
		"publicKeySignature":       base64.StdEncoding.EncodeToString(ed25519.Sign(accountKey, statement)),
	}, token)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("self-approval status=%d body=%v", resp.StatusCode, body)
	}

	// With a certified identity on record, even the very first bundle must
	// be signed by it.
	_, otherKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if resp, body := s.do(t, http.MethodPut, "/api/v1/users/me/recovery", signedRecoveryBody(t, userID, []byte("bundle"), otherKey), token); resp.StatusCode != http.StatusConflict {
		t.Fatalf("uncertified identity status=%d body=%v, want 409", resp.StatusCode, body)
	}
	if resp, body := s.do(t, http.MethodPut, "/api/v1/users/me/recovery", signedRecoveryBody(t, userID, []byte("bundle"), accountKey), token); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("certified identity status=%d body=%v", resp.StatusCode, body)
	}
}
