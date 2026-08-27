// Package securetransport implements HomeBox's ADR-008 Secure Transport
// decision: TLS 1.3 with a self-signed certificate derived from the
// server's persistent ECDSA P-256 identity key, trusted by clients through
// out-of-band fingerprint pinning rather than a certificate authority.
//
// The originally specified Noise_NK_25519_ChaChaPoly_SHA256 handshake has a
// mature Go implementation but no comparably mature, actively maintained
// Dart/Flutter counterpart. Per the specification's own fallback rule
// (§15.2.5) and its ban on hand-rolled or unvetted cryptographic primitives
// (§35.15), this package relies exclusively on each platform's standard TLS
// stack (Go crypto/tls here; Dart dart:io/BoringSSL on the client) instead
// of adopting an unvetted single-maintainer library or writing a custom
// protocol.
//
// The identity key is ECDSA P-256, not Ed25519: Dart's bundled BoringSSL
// TLS client was empirically found to reject an Ed25519 server certificate
// outright during the handshake (HANDSHAKE_FAILURE_ON_CLIENT_HELLO), even
// though Go's crypto/tls and OpenSSL both accept it — Ed25519 support is
// not universal across TLS 1.3 stacks. P-256 is supported by every stack
// this project targets.
//
// The trust model is otherwise identical to what the specification
// describes for Noise: the server exposes a stable fingerprint via
// `homebox server fingerprint`, the operator verifies it out of band (SSH,
// QR code, etc.), and the client pins it before trusting the connection. A
// changed fingerprint always blocks the connection; there is no downgrade
// to plaintext and no automatic re-trust.
package securetransport

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"

	"github.com/homebox/homebox/internal/serveridentity"
)

// certificateNotBefore and certificateNotAfter are fixed, not derived from
// time.Now(), purely so that a freshly generated certificate never looks
// suspiciously narrow in scope. Clients pin the identity's public-key
// fingerprint (ADR-009), not the certificate's validity window, serial, or
// signature bytes, so these dates only need to be a plausible, wide window;
// nothing depends on them being stable across restarts.
var (
	certificateNotBefore = time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	certificateNotAfter  = time.Date(2124, 1, 1, 0, 0, 0, 0, time.UTC)
)

// BuildTLSConfig derives a self-signed TLS certificate from the server's
// identity key. It never generates or persists a separate certificate
// private key: the certificate is a thin wrapper around the same P-256 key
// backing serveridentity.Identity.Fingerprint.
func BuildTLSConfig(identity serveridentity.Identity) (*tls.Config, error) {
	cert, err := selfSignedCertificate(identity)
	if err != nil {
		return nil, err
	}
	return &tls.Config{
		MinVersion:   tls.VersionTLS13,
		Certificates: []tls.Certificate{cert},
	}, nil
}

func selfSignedCertificate(identity serveridentity.Identity) (tls.Certificate, error) {
	digest, err := hex.DecodeString(identity.Fingerprint())
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("decode identity fingerprint: %w", err)
	}
	template := &x509.Certificate{
		SerialNumber:          new(big.Int).SetBytes(digest[:8]),
		Subject:               pkix.Name{CommonName: "homebox-server-identity"},
		NotBefore:             certificateNotBefore,
		NotAfter:              certificateNotAfter,
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		SignatureAlgorithm:    x509.ECDSAWithSHA256,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, identity.PublicKey(), identity.Signer())
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("create self-signed identity certificate: %w", err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: identity.Signer()}, nil
}

// PinnedClientConfig builds a tls.Config that trusts exactly one server
// identity, identified by the hex SHA-256 fingerprint of its P-256 public
// key, instead of a certificate authority. InsecureSkipVerify is
// intentional and safe here: the library's normal chain/hostname validation
// is replaced, not skipped, by VerifyPeerCertificate performing the pinning
// check described in ADR-009. Any fingerprint mismatch — including a
// completely different key algorithm — fails the handshake; there is no
// fallback to unauthenticated plaintext.
func PinnedClientConfig(fingerprint string) (*tls.Config, error) {
	want := strings.ToLower(strings.TrimSpace(fingerprint))
	if len(want) != hex.EncodedLen(32) {
		return nil, errors.New("invalid pinned server fingerprint")
	}
	if _, err := hex.DecodeString(want); err != nil {
		return nil, errors.New("invalid pinned server fingerprint")
	}
	return &tls.Config{
		MinVersion:         tls.VersionTLS13,
		InsecureSkipVerify: true, //nolint:gosec // verified manually below; see ADR-009.
		VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			if len(rawCerts) == 0 {
				return errors.New("server presented no certificate")
			}
			leaf, err := x509.ParseCertificate(rawCerts[0])
			if err != nil {
				return fmt.Errorf("parse server certificate: %w", err)
			}
			pub, ok := leaf.PublicKey.(*ecdsa.PublicKey)
			if !ok {
				return errors.New("server certificate is not a recognized P-256 identity certificate")
			}
			got, err := serveridentity.FingerprintFromPublicKey(pub)
			if err != nil {
				return fmt.Errorf("compute server fingerprint: %w", err)
			}
			if subtle.ConstantTimeCompare([]byte(got), []byte(want)) != 1 {
				return errors.New("SERVER_IDENTITY_CHANGED: server fingerprint does not match the pinned value")
			}
			return nil
		},
	}, nil
}
