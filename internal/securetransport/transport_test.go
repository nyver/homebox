package securetransport

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/homebox/homebox/internal/serveridentity"
)

func TestPinnedClientAcceptsMatchingFingerprintAndRejectsMismatch(t *testing.T) {
	dir := t.TempDir()
	identity, err := serveridentity.LoadOrCreate(dir)
	if err != nil {
		t.Fatal(err)
	}
	serverConfig, err := BuildTLSConfig(identity)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := tls.Listen("tcp", "127.0.0.1:0", serverConfig)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go acceptOnce(listener)

	goodConfig, err := PinnedClientConfig(identity.Fingerprint())
	if err != nil {
		t.Fatal(err)
	}
	conn, err := tls.Dial("tcp", listener.Addr().String(), goodConfig)
	if err != nil {
		t.Fatalf("expected pinned dial to succeed: %v", err)
	}
	conn.Close()

	go acceptOnce(listener)
	otherIdentity, err := serveridentity.LoadOrCreate(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	badConfig, err := PinnedClientConfig(otherIdentity.Fingerprint())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tls.Dial("tcp", listener.Addr().String(), badConfig); err == nil {
		t.Fatal("expected dial with wrong pinned fingerprint to fail")
	}
}

func TestBuildTLSConfigKeepsTheSameFingerprintAcrossRestarts(t *testing.T) {
	// ECDSA signatures are randomized, so regenerated certificate bytes
	// differ across restarts even for the same key — only the embedded
	// public key (and therefore the pinned fingerprint) needs to stay
	// stable, which is what clients actually rely on (ADR-009).
	dir := t.TempDir()
	identity, err := serveridentity.LoadOrCreate(dir)
	if err != nil {
		t.Fatal(err)
	}
	first, err := selfSignedCertificate(identity)
	if err != nil {
		t.Fatal(err)
	}
	reloaded, err := serveridentity.LoadOrCreate(dir)
	if err != nil {
		t.Fatal(err)
	}
	second, err := selfSignedCertificate(reloaded)
	if err != nil {
		t.Fatal(err)
	}
	firstLeaf, err := x509.ParseCertificate(first.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	secondLeaf, err := x509.ParseCertificate(second.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	firstFingerprint, err := serveridentity.FingerprintFromPublicKey(firstLeaf.PublicKey.(*ecdsa.PublicKey))
	if err != nil {
		t.Fatal(err)
	}
	secondFingerprint, err := serveridentity.FingerprintFromPublicKey(secondLeaf.PublicKey.(*ecdsa.PublicKey))
	if err != nil {
		t.Fatal(err)
	}
	if firstFingerprint != secondFingerprint || firstFingerprint != identity.Fingerprint() {
		t.Fatalf("fingerprint changed across restarts: %s vs %s (identity: %s)", firstFingerprint, secondFingerprint, identity.Fingerprint())
	}
}

func TestInvalidPinnedFingerprintIsRejected(t *testing.T) {
	if _, err := PinnedClientConfig("not-hex"); err == nil {
		t.Fatal("expected an error for a non-hex fingerprint")
	}
	if _, err := PinnedClientConfig("aa"); err == nil {
		t.Fatal("expected an error for a short fingerprint")
	}
}

func acceptOnce(listener net.Listener) {
	conn, err := listener.Accept()
	if err != nil {
		return
	}
	defer conn.Close()
	_, _ = io.Copy(io.Discard, conn)
}

// writeOperatorCertificate writes a self-signed certificate and its key to
// PEM files, the way an operator would provide them.
func writeOperatorCertificate(t *testing.T, key crypto.Signer) (certFile, keyFile string) {
	t.Helper()
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "homebox.example"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, key.Public(), key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	certFile, keyFile = filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	if err := os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}), 0o600); err != nil {
		t.Fatal(err)
	}
	return certFile, keyFile
}

func TestOperatorCertificateServesTLS13AndReportsItsPinnedFingerprint(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	certFile, keyFile := writeOperatorCertificate(t, key)
	config, fingerprint, err := LoadOperatorTLSConfig(certFile, keyFile)
	if err != nil {
		t.Fatal(err)
	}
	if config.MinVersion != tls.VersionTLS13 {
		t.Fatalf("operator TLS must require TLS 1.3, got %x", config.MinVersion)
	}
	want, err := serveridentity.FingerprintFromPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	if fingerprint != want {
		t.Fatalf("fingerprint=%s, want the certificate key's %s", fingerprint, want)
	}
	listener, err := tls.Listen("tcp", "127.0.0.1:0", config)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go acceptOnce(listener)
	clientConfig, err := PinnedClientConfig(fingerprint)
	if err != nil {
		t.Fatal(err)
	}
	conn, err := tls.Dial("tcp", listener.Addr().String(), clientConfig)
	if err != nil {
		t.Fatalf("a client pinning the reported fingerprint must connect: %v", err)
	}
	conn.Close()
}

func TestOperatorCertificateMustUseP256(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	certFile, keyFile := writeOperatorCertificate(t, key)
	if _, _, err := LoadOperatorTLSConfig(certFile, keyFile); err == nil {
		t.Fatal("an RSA operator certificate must be rejected: clients cannot pin it")
	}
}
