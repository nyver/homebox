package maintenance

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/homebox/homebox/internal/database"
)

func TestRunUsesTwoPassGracePeriodForUnreferencedAndOrphanBlobs(t *testing.T) {
	storage := t.TempDir()
	db, err := database.Open(storage)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := os.MkdirAll(filepath.Join(storage, "blobs"), 0o700); err != nil {
		t.Fatal(err)
	}
	storedID := uuid.NewString()
	storedPath := "blobs/" + storedID + ".hbxblob"
	storedCiphertext := []byte("unreferenced ciphertext")
	storedDigest := sha256.Sum256(storedCiphertext)
	if err := os.WriteFile(filepath.Join(storage, filepath.FromSlash(storedPath)), storedCiphertext, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO blobs (id,ciphertext_size,storage_rel_path,ciphertext_sha256,format_version,chunk_count,created_at)
		VALUES (?,?,?,?,1,1,?)`, storedID, len(storedCiphertext), storedPath, hex.EncodeToString(storedDigest[:]), "2026-01-01T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	orphanPath := "blobs/" + uuid.NewString() + ".hbxblob"
	if err := os.WriteFile(filepath.Join(storage, filepath.FromSlash(orphanPath)), []byte("orphan ciphertext"), 0o600); err != nil {
		t.Fatal(err)
	}
	service, err := New(db, storage, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC)
	service.now = func() time.Time { return now }
	first, err := service.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if first.UnreferencedBlobs != 0 || first.OrphanBlobFiles != 0 {
		t.Fatalf("first GC pass deleted data: %#v", first)
	}
	for _, path := range []string{storedPath, orphanPath} {
		if _, err := os.Stat(filepath.Join(storage, filepath.FromSlash(path))); err != nil {
			t.Fatalf("first pass removed %s: %v", path, err)
		}
	}
	now = now.Add(2 * time.Hour)
	second, err := service.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if second.UnreferencedBlobs != 1 || second.OrphanBlobFiles != 1 {
		t.Fatalf("second GC pass=%#v", second)
	}
	for _, path := range []string{storedPath, orphanPath} {
		if _, err := os.Stat(filepath.Join(storage, filepath.FromSlash(path))); !os.IsNotExist(err) {
			t.Fatalf("second pass did not remove %s: %v", path, err)
		}
	}
	var count int
	if err := db.QueryRow("SELECT COUNT(*) FROM blobs WHERE id=?", storedID).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatal("unreferenced blob record remained after second pass")
	}
}

func TestRunCleansExpiredControlRecordsAndUploadCiphertext(t *testing.T) {
	storage := t.TempDir()
	db, err := database.Open(storage)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	userID, deviceID, uploadID := uuid.NewString(), uuid.NewString(), uuid.NewString()
	old := "2026-01-01T00:00:00Z"
	if _, err := db.Exec(`INSERT INTO users (id,username,username_norm,password_hash,role,status,created_at,updated_at)
		VALUES (?,?,?,'hash','ADMIN','ACTIVE',?,?)`, userID, "admin", "admin", old, old); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO devices (id,user_id,name,platform,e2ee_public_key,e2ee_key_version,created_at,last_seen_at)
		VALUES (?,?,?,'WINDOWS',X'01',1,?,?)`, deviceID, userID, "device", old, old); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO access_tokens (id,user_id,device_id,token_hash,created_at,expires_at) VALUES (?,?,?,X'01',?,?)`, uuid.NewString(), userID, deviceID, old, old); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO refresh_tokens (id,user_id,device_id,token_hash,created_at,expires_at) VALUES (?,?,?,X'02',?,?)`, uuid.NewString(), userID, deviceID, old, old); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO processed_operations (operation_id,user_id,device_id,operation_type,result_code,created_at,expires_at)
		VALUES (?,?,?,'TEST','OK',?,?)`, uuid.NewString(), userID, deviceID, old, old); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO upload_sessions (id,user_id,device_id,file_version_id,blob_id,chunk_size,chunk_count,max_ciphertext_size,wrapped_file_key,e2ee_header,status,created_at,expires_at)
		VALUES (?,?,?,?,?,1,1,1,X'01',X'01','OPEN',?,?)`, uploadID, userID, deviceID, uuid.NewString(), uuid.NewString(), old, old); err != nil {
		t.Fatal(err)
	}
	uploadDir := filepath.Join(storage, "temp", "uploads", uploadID)
	if err := os.MkdirAll(uploadDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(uploadDir, "0.chunk"), []byte("temporary ciphertext"), 0o600); err != nil {
		t.Fatal(err)
	}
	service, err := New(db, storage, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	service.now = func() time.Time { return time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC) }
	result, err := service.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if result.ExpiredUploads != 1 || result.ExpiredAccessTokens != 1 || result.ExpiredRefreshTokens != 1 || result.ExpiredOperations != 1 {
		t.Fatalf("cleanup result=%#v", result)
	}
	if _, err := os.Stat(uploadDir); !os.IsNotExist(err) {
		t.Fatalf("expired upload directory still exists: %v", err)
	}
}
