package serveridentity

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

const fileMode os.FileMode = 0o600

// Identity is the server's persistent transport identity: an ECDSA P-256
// key pair (ADR-008). P-256 was chosen over Ed25519 after empirically
// finding that Dart's bundled BoringSSL TLS client rejects an Ed25519
// server certificate outright during the handshake
// (HANDSHAKE_FAILURE_ON_CLIENT_HELLO) even though Go's crypto/tls and
// OpenSSL both accept it — Ed25519 is not universally supported in TLS 1.3
// stacks. P-256 is supported everywhere this project targets: Go
// crypto/tls, Dart/BoringSSL, and OpenSSL.
type Identity struct {
	privateKey  *ecdsa.PrivateKey
	fingerprint string
}

func LoadOrCreate(storagePath string) (Identity, error) {
	keyPath := filepath.Join(storagePath, "keys", "server_identity.key")
	if err := os.MkdirAll(filepath.Dir(keyPath), 0o700); err != nil {
		return Identity{}, fmt.Errorf("create identity directory: %w", err)
	}
	encoded, err := os.ReadFile(keyPath)
	if err == nil {
		der, decodeErr := base64.RawStdEncoding.DecodeString(string(encoded))
		if decodeErr != nil {
			return Identity{}, errors.New("server identity key is invalid")
		}
		privateKey, parseErr := x509.ParseECPrivateKey(der)
		if parseErr != nil {
			return Identity{}, errors.New("server identity key is invalid")
		}
		return newIdentity(privateKey)
	}
	if !errors.Is(err, os.ErrNotExist) {
		return Identity{}, fmt.Errorf("read server identity: %w", err)
	}
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return Identity{}, fmt.Errorf("generate server identity: %w", err)
	}
	der, err := x509.MarshalECPrivateKey(privateKey)
	if err != nil {
		return Identity{}, fmt.Errorf("encode server identity: %w", err)
	}
	if err := os.WriteFile(keyPath, []byte(base64.RawStdEncoding.EncodeToString(der)), fileMode); err != nil {
		return Identity{}, fmt.Errorf("write server identity: %w", err)
	}
	return newIdentity(privateKey)
}

func newIdentity(privateKey *ecdsa.PrivateKey) (Identity, error) {
	fingerprint, err := FingerprintFromPublicKey(&privateKey.PublicKey)
	if err != nil {
		return Identity{}, fmt.Errorf("invalid server identity key: %w", err)
	}
	return Identity{privateKey: privateKey, fingerprint: fingerprint}, nil
}

func (i Identity) PublicKey() *ecdsa.PublicKey { return &i.privateKey.PublicKey }

// Signer exposes the identity key as a crypto.Signer so it can also serve as
// the key behind the server's self-signed TLS certificate (see
// internal/securetransport). The private key itself never leaves this
// package in any other form.
func (i Identity) Signer() crypto.Signer { return i.privateKey }

func (i Identity) Fingerprint() string { return i.fingerprint }

// FingerprintFromPublicKey returns the lowercase hex SHA-256 fingerprint of
// a P-256 public key's canonical uncompressed-point encoding
// (0x04 || X || Y, 65 bytes total). Per RFC 5480, those are exactly the
// trailing bytes of the key's SubjectPublicKeyInfo BIT STRING in any X.509
// certificate carrying it — so a peer can recompute this same fingerprint
// directly from a certificate it received on the wire (see
// internal/securetransport.PinnedClientConfig and the Flutter client's
// equivalent fixed-prefix extraction) without sharing a library.
func FingerprintFromPublicKey(pub *ecdsa.PublicKey) (string, error) {
	ecdhPub, err := pub.ECDH()
	if err != nil {
		return "", fmt.Errorf("not a valid P-256 point: %w", err)
	}
	sum := sha256.Sum256(ecdhPub.Bytes())
	return hex.EncodeToString(sum[:]), nil
}
