package uploads

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/homebox/homebox/internal/database"
)

func TestCompleteStoresOnlyJoinedCiphertextAndIsIdempotent(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	db, err := database.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	userID, deviceID, nodeID := seedFileNode(t, ctx, db)
	s, err := New(db, dir, 100, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	expectedRevision := int64(0)
	input := CreateInput{UserID: userID, DeviceID: deviceID, TargetNodeID: nodeID, FileVersionID: uuid.NewString(), BlobID: uuid.NewString(), ExpectedRevision: &expectedRevision, ChunkSize: 50, ChunkCount: 2, MetadataKeyVersion: 2, MetadataCiphertext: []byte("encrypted-metadata"), WrappedFileKey: []byte("wrapped-key"), E2EEHeader: []byte("e2ee-header")}
	session, err := s.Create(ctx, input)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.PutChunk(ctx, userID, deviceID, session.ID, 0, []byte("ciphertext-one")); err != nil {
		t.Fatal(err)
	}
	if err := s.PutChunk(ctx, userID, deviceID, session.ID, 1, []byte("ciphertext-two")); err != nil {
		t.Fatal(err)
	}
	operationID := uuid.NewString()
	result, err := s.Complete(ctx, session.ID, CompleteInput{UserID: userID, DeviceID: deviceID, OperationID: operationID, KeyScopeID: uuid.NewString(), KeyVersion: 1, SyncPayloadCiphertext: []byte("encrypted-change")})
	if err != nil {
		t.Fatal(err)
	}
	if result.BlobID != input.BlobID || result.FileVersionID != input.FileVersionID || result.Revision < 1 {
		t.Fatalf("unexpected result: %#v", result)
	}
	stored, err := os.ReadFile(filepath.Join(dir, "blobs", input.BlobID+".hbxblob"))
	if err != nil {
		t.Fatal(err)
	}
	if string(stored) != "ciphertext-oneciphertext-two" {
		t.Fatalf("unexpected stored bytes: %q", stored)
	}
	var storedMetadata []byte
	var storedMetadataVersion int
	if err := db.QueryRowContext(ctx, "SELECT metadata_ciphertext,metadata_key_version FROM nodes WHERE id=?", nodeID).Scan(&storedMetadata, &storedMetadataVersion); err != nil {
		t.Fatal(err)
	}
	if string(storedMetadata) != "encrypted-metadata" || storedMetadataVersion != 2 {
		t.Fatalf("metadata was not committed atomically: ciphertext=%q version=%d", storedMetadata, storedMetadataVersion)
	}
	again, err := s.Complete(ctx, session.ID, CompleteInput{UserID: userID, DeviceID: deviceID, OperationID: operationID, KeyScopeID: uuid.NewString(), KeyVersion: 1})
	if err != nil {
		t.Fatal(err)
	}
	if again != result {
		t.Fatalf("idempotent result=%#v, want %#v", again, result)
	}
}

func TestConflictingRetryCannotReplaceAcceptedChunk(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	db, err := database.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	userID, deviceID, nodeID := seedFileNode(t, ctx, db)
	s, err := New(db, dir, 100, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	expectedRevision := int64(0)
	session, err := s.Create(ctx, CreateInput{UserID: userID, DeviceID: deviceID, TargetNodeID: nodeID, FileVersionID: uuid.NewString(), BlobID: uuid.NewString(), ExpectedRevision: &expectedRevision, ChunkSize: 100, ChunkCount: 1, MetadataKeyVersion: 1, MetadataCiphertext: []byte("m"), WrappedFileKey: []byte("k"), E2EEHeader: []byte("h")})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.PutChunk(ctx, userID, deviceID, session.ID, 0, []byte("first")); err != nil {
		t.Fatal(err)
	}
	if err := s.PutChunk(ctx, userID, deviceID, session.ID, 0, []byte("second")); err != ErrChunkConflict {
		t.Fatalf("error=%v, want %v", err, ErrChunkConflict)
	}
	stored, err := os.ReadFile(filepath.Join(dir, "temp", "uploads", session.ID, "0.chunk"))
	if err != nil {
		t.Fatal(err)
	}
	if string(stored) != "first" {
		t.Fatalf("chunk was replaced: %q", stored)
	}
}

func TestCreateRequiresExpectedRevision(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	db, err := database.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	userID, deviceID, nodeID := seedFileNode(t, ctx, db)
	s, err := New(db, dir, 100, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Create(ctx, CreateInput{
		UserID: userID, DeviceID: deviceID, TargetNodeID: nodeID,
		FileVersionID: uuid.NewString(), BlobID: uuid.NewString(),
		ChunkSize: 100, ChunkCount: 1, MetadataKeyVersion: 1,
		MetadataCiphertext: []byte("m"), WrappedFileKey: []byte("k"), E2EEHeader: []byte("h"),
	})
	if err == nil {
		t.Fatal("upload creation without an expected revision was accepted")
	}
}

func TestAbortRemovesTempChunksAndIsIdempotent(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	db, err := database.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	userID, deviceID, nodeID := seedFileNode(t, ctx, db)
	s, err := New(db, dir, 100, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	expectedRevision := int64(0)
	session, err := s.Create(ctx, CreateInput{UserID: userID, DeviceID: deviceID, TargetNodeID: nodeID, FileVersionID: uuid.NewString(), BlobID: uuid.NewString(), ExpectedRevision: &expectedRevision,
		ChunkSize: 50, ChunkCount: 1, MetadataKeyVersion: 1, MetadataCiphertext: []byte("m"), WrappedFileKey: []byte("k"), E2EEHeader: []byte("h")})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.PutChunk(ctx, userID, deviceID, session.ID, 0, []byte("chunk")); err != nil {
		t.Fatal(err)
	}
	if err := s.Abort(ctx, userID, deviceID, session.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(s.uploadDir(session.ID)); !os.IsNotExist(err) {
		t.Fatalf("expected the temp upload directory to be removed, stat err=%v", err)
	}
	if err := s.Abort(ctx, userID, deviceID, session.ID); err != nil {
		t.Fatalf("aborting an already-aborted session should be a no-op: %v", err)
	}
	if err := s.PutChunk(ctx, userID, deviceID, session.ID, 0, []byte("chunk")); err != ErrInvalidState {
		t.Fatalf("putting a chunk after abort: error=%v, want %v", err, ErrInvalidState)
	}
}

func seedFileNode(t *testing.T, ctx context.Context, db *sql.DB) (string, string, string) {
	t.Helper()
	userID, deviceID, nodeID := uuid.NewString(), uuid.NewString(), uuid.NewString()
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := db.ExecContext(ctx, `INSERT INTO users (id,username,username_norm,password_hash,role,status,created_at,updated_at) VALUES (?,?,?,'hash','USER','ACTIVE',?,?)`, userID, "user", "user", now, now); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `INSERT INTO devices (id,user_id,name,platform,e2ee_public_key,e2ee_key_version,created_at,last_seen_at) VALUES (?,?,?,'WINDOWS',?,1,?,?)`, deviceID, userID, "device", []byte("public-key"), now, now); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `INSERT INTO nodes (id,owner_id,node_type,metadata_ciphertext,metadata_key_version,revision,created_at,updated_at) VALUES (?,?,'FILE',?,1,0,?,?)`, nodeID, userID, []byte("metadata"), now, now); err != nil {
		t.Fatal(err)
	}
	return userID, deviceID, nodeID
}
