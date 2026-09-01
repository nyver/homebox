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
	service, err := New(db, storage, time.Hour, 72*time.Hour)
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
	service, err := New(db, storage, time.Hour, 72*time.Hour)
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

func TestRunPermanentlyDeletesExpiredTrashSubtree(t *testing.T) {
	storage := t.TempDir()
	db, err := database.Open(storage)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	ownerID, recipientID := uuid.NewString(), uuid.NewString()
	ownerDeviceID, recipientDeviceID := uuid.NewString(), uuid.NewString()
	old := "2026-01-01T00:00:00Z"
	young := "2026-01-04T00:00:01Z"
	now := time.Date(2026, 1, 7, 0, 0, 0, 0, time.UTC)
	for _, user := range []struct{ id, name string }{{ownerID, "owner"}, {recipientID, "recipient"}} {
		if _, err := db.Exec(`INSERT INTO users (id,username,username_norm,password_hash,role,status,created_at,updated_at)
			VALUES (?,?,?,'hash','USER','ACTIVE',?,?)`, user.id, user.name, user.name, old, old); err != nil {
			t.Fatal(err)
		}
	}
	for _, device := range []struct{ id, userID string }{{ownerDeviceID, ownerID}, {recipientDeviceID, recipientID}} {
		if _, err := db.Exec(`INSERT INTO devices (id,user_id,name,platform,e2ee_public_key,e2ee_key_version,created_at,last_seen_at)
			VALUES (?,?,?,'OTHER',X'01',1,?,?)`, device.id, device.userID, "device", old, old); err != nil {
			t.Fatal(err)
		}
	}

	rootID, childID, youngID := uuid.NewString(), uuid.NewString(), uuid.NewString()
	versionID, blobID := uuid.NewString(), uuid.NewString()
	if _, err := db.Exec(`INSERT INTO nodes (id,owner_id,parent_id,node_type,metadata_ciphertext,metadata_key_version,current_version_id,revision,created_at,updated_at,deleted_at)
		VALUES (?,?,NULL,'DIRECTORY',X'01',1,NULL,1,?,?,?)`, rootID, ownerID, old, old, old); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO nodes (id,owner_id,parent_id,node_type,metadata_ciphertext,metadata_key_version,current_version_id,revision,created_at,updated_at,deleted_at)
		VALUES (?,?,?,'FILE',X'01',1,?,1,?,?,NULL)`, childID, ownerID, rootID, versionID, old, old); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO nodes (id,owner_id,parent_id,node_type,metadata_ciphertext,metadata_key_version,current_version_id,revision,created_at,updated_at,deleted_at)
		VALUES (?,?,NULL,'FILE',X'01',1,NULL,1,?,?,?)`, youngID, ownerID, old, young, young); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO blobs (id,ciphertext_size,storage_rel_path,ciphertext_sha256,format_version,chunk_count,created_at)
		VALUES (?,1,?,'digest',1,1,?)`, blobID, "blobs/"+blobID+".hbxblob", old); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO file_versions (id,node_id,blob_id,e2ee_header,wrapped_file_key,key_scope_id,key_version,created_at,created_by_device_id,revision)
		VALUES (?,?,?,X'01',X'01',?,1,?,?,1)`, versionID, childID, blobID, ownerID, old, ownerDeviceID); err != nil {
		t.Fatal(err)
	}

	shareID := uuid.NewString()
	if _, err := db.Exec(`INSERT INTO shares (id,node_id,owner_user_id,target_user_id,permission,key_envelope,key_version,created_at,created_by)
		VALUES (?,?,?,?,'READ',X'01',1,?,?)`, shareID, childID, ownerID, recipientID, old, ownerID); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO share_device_envelopes (id,share_id,target_device_id,key_version,envelope_ciphertext,created_at)
		VALUES (?,?,?,1,X'01',?)`, uuid.NewString(), shareID, recipientDeviceID, old); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("INSERT INTO favorites (user_id,node_id,created_at) VALUES (?,?,?)", ownerID, childID, old); err != nil {
		t.Fatal(err)
	}
	uploadID := uuid.NewString()
	if _, err := db.Exec(`INSERT INTO upload_sessions (id,user_id,device_id,target_node_id,file_version_id,blob_id,chunk_size,chunk_count,max_ciphertext_size,wrapped_file_key,e2ee_header,status,created_at,expires_at)
		VALUES (?,?,?,?,?,?,1,1,1,X'01',X'01','COMPLETED',?,?)`, uploadID, ownerID, ownerDeviceID, childID, versionID, blobID, old, old); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO upload_chunks (upload_id,chunk_no,ciphertext_size,ciphertext_sha256,temp_rel_path,received_at)
		VALUES (?,0,1,'digest','temp/chunk',?)`, uploadID, old); err != nil {
		t.Fatal(err)
	}
	uploadDir := filepath.Join(storage, "temp", "uploads", uploadID)
	if err := os.MkdirAll(uploadDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(uploadDir, "0.chunk"), []byte("stale ciphertext"), 0o600); err != nil {
		t.Fatal(err)
	}

	service, err := New(db, storage, time.Hour, 72*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	service.now = func() time.Time { return now }
	result, err := service.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if result.ExpiredTrashItems != 1 {
		t.Fatalf("expired Trash items = %d, want 1", result.ExpiredTrashItems)
	}

	assertCount := func(query string, want int, args ...any) {
		t.Helper()
		var got int
		if err := db.QueryRow(query, args...).Scan(&got); err != nil {
			t.Fatal(err)
		}
		if got != want {
			t.Fatalf("%s: count = %d, want %d", query, got, want)
		}
	}
	assertCount("SELECT COUNT(*) FROM nodes WHERE id IN (?,?)", 0, rootID, childID)
	assertCount("SELECT COUNT(*) FROM nodes WHERE id=?", 1, youngID)
	assertCount("SELECT COUNT(*) FROM file_versions WHERE id=?", 0, versionID)
	assertCount("SELECT COUNT(*) FROM shares WHERE id=?", 0, shareID)
	assertCount("SELECT COUNT(*) FROM share_device_envelopes WHERE share_id=?", 0, shareID)
	assertCount("SELECT COUNT(*) FROM favorites WHERE node_id=?", 0, childID)
	assertCount("SELECT COUNT(*) FROM upload_sessions WHERE id=?", 0, uploadID)
	assertCount("SELECT COUNT(*) FROM upload_chunks WHERE upload_id=?", 0, uploadID)
	assertCount("SELECT COUNT(*) FROM blobs WHERE id=?", 1, blobID)
	assertCount("SELECT COUNT(*) FROM gc_blob_candidates WHERE blob_id=?", 1, blobID)
	assertCount("SELECT COUNT(*) FROM sync_changes WHERE operation='PURGE' AND node_id IN (?,?)", 2, rootID, childID)
	if _, err := os.Stat(uploadDir); !os.IsNotExist(err) {
		t.Fatalf("expired Trash upload directory still exists: %v", err)
	}
}
