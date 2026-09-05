// Package deviceauth defines the canonical statement signed by a HomeBox
// account identity when it authorizes an X25519 device key.
package deviceauth

import (
	"crypto/ed25519"
	"encoding/binary"
	"errors"

	"github.com/google/uuid"
)

const SignatureVersion = 1

var ErrInvalidCertificate = errors.New("invalid device key certificate")

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
