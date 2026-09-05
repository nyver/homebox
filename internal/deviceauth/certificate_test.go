package deviceauth

import (
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"testing"

	"github.com/google/uuid"
)

func TestVerifyBindsDeviceCertificateContext(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	userID, deviceID := uuid.NewString(), uuid.NewString()
	deviceKey := make([]byte, 32)
	if _, err := rand.Read(deviceKey); err != nil {
		t.Fatal(err)
	}
	statement, err := Statement(userID, deviceID, 1, deviceKey)
	if err != nil {
		t.Fatal(err)
	}
	signature := ed25519.Sign(privateKey, statement)
	if err := Verify(publicKey, signature, userID, deviceID, 1, deviceKey); err != nil {
		t.Fatalf("valid certificate rejected: %v", err)
	}
	tampered := append([]byte(nil), deviceKey...)
	tampered[0] ^= 1
	if err := Verify(publicKey, signature, userID, deviceID, 1, tampered); !errors.Is(err, ErrInvalidCertificate) {
		t.Fatalf("tampered key error=%v, want %v", err, ErrInvalidCertificate)
	}
}
