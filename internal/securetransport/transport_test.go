package securetransport

import (
	"crypto/ecdsa"
	"crypto/tls"
	"crypto/x509"
	"io"
	"net"
	"testing"

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
