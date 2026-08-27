package serveridentity

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

const fileMode os.FileMode = 0o600

type Identity struct{ privateKey ed25519.PrivateKey }

func LoadOrCreate(storagePath string) (Identity, error) {
	keyPath := filepath.Join(storagePath, "keys", "server_identity.key")
	if err := os.MkdirAll(filepath.Dir(keyPath), 0o700); err != nil {
		return Identity{}, fmt.Errorf("create identity directory: %w", err)
	}
	encoded, err := os.ReadFile(keyPath)
	if err == nil {
		privateKey, err := base64.RawStdEncoding.DecodeString(string(encoded))
		if err != nil || len(privateKey) != ed25519.PrivateKeySize {
			return Identity{}, errors.New("server identity key is invalid")
		}
		return Identity{privateKey: ed25519.PrivateKey(privateKey)}, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return Identity{}, fmt.Errorf("read server identity: %w", err)
	}
	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return Identity{}, fmt.Errorf("generate server identity: %w", err)
	}
	if err := os.WriteFile(keyPath, []byte(base64.RawStdEncoding.EncodeToString(privateKey)), fileMode); err != nil {
		return Identity{}, fmt.Errorf("write server identity: %w", err)
	}
	return Identity{privateKey: privateKey}, nil
}

func (i Identity) PublicKey() ed25519.PublicKey { return i.privateKey.Public().(ed25519.PublicKey) }

func (i Identity) Fingerprint() string {
	sum := sha256.Sum256(i.PublicKey())
	return hex.EncodeToString(sum[:])
}
