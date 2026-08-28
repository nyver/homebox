package backup

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"

	"github.com/google/uuid"
	"github.com/homebox/homebox/internal/database"
	"github.com/homebox/homebox/internal/serveridentity"
)

func TestCreateAndRestoreRoundTrip(t *testing.T) {
	root := t.TempDir()
	storage := filepath.Join(root, "source")
	db, err := database.Open(storage)
	if err != nil {
		t.Fatal(err)
	}
	identity, err := serveridentity.LoadOrCreate(storage)
	if err != nil {
		t.Fatal(err)
	}
	ciphertext := []byte("ciphertext-only test payload")
	digest := sha256.Sum256(ciphertext)
	blobID := uuid.NewString()
	relativePath := filepath.ToSlash(filepath.Join("blobs", blobID+".hbxblob"))
	if err := os.MkdirAll(filepath.Join(storage, "blobs"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(storage, filepath.FromSlash(relativePath)), ciphertext, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO blobs (id,ciphertext_size,storage_rel_path,ciphertext_sha256,format_version,chunk_count,created_at)
		VALUES (?,?,?,?,1,1,'2026-01-01T00:00:00Z')`, blobID, len(ciphertext), relativePath, hex.EncodeToString(digest[:])); err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(root, "config.yaml")
	if err := os.WriteFile(configPath, []byte("storage:\n  path: ./source\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	backupPath := filepath.Join(root, "backup")
	if err := Create(context.Background(), db, storage, configPath, backupPath); err != nil {
		t.Fatalf("create backup: %v", err)
	}
	if _, err := os.Stat(filepath.Join(backupPath, "temp")); !os.IsNotExist(err) {
		t.Fatalf("backup must not contain temporary upload data, stat error=%v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	restoredStorage := filepath.Join(root, "restored")
	if err := Restore(context.Background(), backupPath, restoredStorage); err != nil {
		t.Fatalf("restore backup: %v", err)
	}
	restoredIdentity, err := serveridentity.LoadOrCreate(restoredStorage)
	if err != nil {
		t.Fatal(err)
	}
	if restoredIdentity.Fingerprint() != identity.Fingerprint() {
		t.Fatalf("identity fingerprint changed after restore: got %s want %s", restoredIdentity.Fingerprint(), identity.Fingerprint())
	}
	restoredBlob, err := os.ReadFile(filepath.Join(restoredStorage, filepath.FromSlash(relativePath)))
	if err != nil {
		t.Fatal(err)
	}
	if string(restoredBlob) != string(ciphertext) {
		t.Fatalf("restored ciphertext=%q want %q", restoredBlob, ciphertext)
	}
	restoredDB, err := database.Open(restoredStorage)
	if err != nil {
		t.Fatal(err)
	}
	defer restoredDB.Close()
	var restoredDigest string
	if err := restoredDB.QueryRow("SELECT ciphertext_sha256 FROM blobs WHERE id=?", blobID).Scan(&restoredDigest); err != nil {
		t.Fatal(err)
	}
	if restoredDigest != hex.EncodeToString(digest[:]) {
		t.Fatalf("restored digest=%s", restoredDigest)
	}
}

func TestRestoreRejectsCorruptedBackupWithoutCreatingTarget(t *testing.T) {
	root := t.TempDir()
	storage := filepath.Join(root, "source")
	db, err := database.Open(storage)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := serveridentity.LoadOrCreate(storage); err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(root, "config.yaml")
	if err := os.WriteFile(configPath, []byte("storage:\n  path: ./source\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	backupPath := filepath.Join(root, "backup")
	if err := Create(context.Background(), db, storage, configPath, backupPath); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(backupPath, "database", "homebox.db"), []byte("not a SQLite database"), 0o600); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(root, "restored")
	if err := Restore(context.Background(), backupPath, target); err == nil {
		t.Fatal("restore accepted a corrupted backup")
	}
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatalf("restore created target after validation failure: %v", err)
	}
}

func TestCreateRejectsBackupInsideStorage(t *testing.T) {
	root := t.TempDir()
	storage := filepath.Join(root, "source")
	db, err := database.Open(storage)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := serveridentity.LoadOrCreate(storage); err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(root, "config.yaml")
	if err := os.WriteFile(configPath, []byte("storage:\n  path: ./source\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := Create(context.Background(), db, storage, configPath, filepath.Join(storage, "backups", "one")); err == nil {
		t.Fatal("backup inside storage was accepted")
	}
}
