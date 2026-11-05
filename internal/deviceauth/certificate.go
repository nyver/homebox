// Package deviceauth defines the canonical statements signed by a HomeBox
// account identity: authorizing an X25519 device key, and publishing the
// account's encrypted recovery bundle.
package deviceauth

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"errors"

	"github.com/google/uuid"
)

const SignatureVersion = 1

var (
	ErrInvalidCertificate = errors.New("invalid device key certificate")
	ErrInvalidSignature   = errors.New("invalid account identity signature")
)

// Statement returns the versioned, unambiguous bytes covered by the account
// Ed25519 signature. UUIDs are encoded as 16 raw bytes so alternative textual
// spellings cannot produce different certificates for the same identifiers.
func Statement(userID, deviceID string, keyVersion int, devicePublicKey []byte) ([]byte, error) {
	if keyVersion < 1 || keyVersion > int(^uint32(0)) || len(devicePublicKey) != 32 {
		return nil, ErrInvalidCertificate
	}
	userUUID, err := uuid.Parse(userID)
	if err != nil {
		return nil, ErrInvalidCertificate
	}
	deviceUUID, err := uuid.Parse(deviceID)
	if err != nil {
		return nil, ErrInvalidCertificate
	}
	statement := make([]byte, 5+2+16+16+4+32)
	copy(statement, "HBXDS")
	binary.BigEndian.PutUint16(statement[5:7], SignatureVersion)
	copy(statement[7:23], userUUID[:])
	copy(statement[23:39], deviceUUID[:])
	binary.BigEndian.PutUint32(statement[39:43], uint32(keyVersion))
	copy(statement[43:75], devicePublicKey)
	return statement, nil
}

// Verify checks a device certificate without trusting any server-side device
// metadata beyond the values included in the signed statement.
func Verify(accountPublicKey, signature []byte, userID, deviceID string, keyVersion int, devicePublicKey []byte) error {
	if len(accountPublicKey) != ed25519.PublicKeySize || len(signature) != ed25519.SignatureSize {
		return ErrInvalidCertificate
	}
	statement, err := Statement(userID, deviceID, keyVersion, devicePublicKey)
	if err != nil || !ed25519.Verify(ed25519.PublicKey(accountPublicKey), statement, signature) {
		return ErrInvalidCertificate
	}
	return nil
}

// RecoveryBundleStatement returns the bytes an account identity signs to
// publish an opaque recovery bundle. Binding the account ID stops a bundle
// signed for one account from being accepted for another.
func RecoveryBundleStatement(userID string, bundle []byte) ([]byte, error) {
	userUUID, err := uuid.Parse(userID)
	if err != nil || len(bundle) == 0 {
		return nil, ErrInvalidSignature
	}
	digest := sha256.Sum256(bundle)
	statement := make([]byte, 5+2+16+32)
	copy(statement, "HBXRB")
	binary.BigEndian.PutUint16(statement[5:7], SignatureVersion)
	copy(statement[7:23], userUUID[:])
	copy(statement[23:55], digest[:])
	return statement, nil
}

// VerifyRecoveryBundle checks that accountPublicKey signed bundle for userID.
func VerifyRecoveryBundle(accountPublicKey, signature []byte, userID string, bundle []byte) error {
	if len(accountPublicKey) != ed25519.PublicKeySize || len(signature) != ed25519.SignatureSize {
		return ErrInvalidSignature
	}
	statement, err := RecoveryBundleStatement(userID, bundle)
	if err != nil || !ed25519.Verify(ed25519.PublicKey(accountPublicKey), statement, signature) {
		return ErrInvalidSignature
	}
	return nil
}
