package uploads

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/homebox/homebox/internal/apierror"
	"github.com/homebox/homebox/internal/database"
)

func newSecurityTestService(t *testing.T) (context.Context, *sql.DB, *Service, string, string, string, string) {
	t.Helper()
	ctx := context.Background()
	dir := t.TempDir()
	db, err := database.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	userID, deviceID, nodeID := seedFileNode(t, ctx, db)
	s, err := New(db, dir, 1<<20, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	return ctx, db, s, dir, userID, deviceID, nodeID
}

func seedSecondFileNode(t *testing.T, ctx context.Context, db *sql.DB, ownerID string) string {
	t.Helper()
	nodeID := uuid.NewString()
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := db.ExecContext(ctx, `INSERT INTO nodes (id,owner_id,node_type,metadata_ciphertext,metadata_key_version,revision,created_at,updated_at) VALUES (?,?,'FILE',?,1,0,?,?)`, nodeID, ownerID, []byte("metadata"), now, now); err != nil {
		t.Fatal(err)
	}
	return nodeID
}

func uploadOneChunk(t *testing.T, ctx context.Context, s *Service, userID, deviceID, nodeID, blobID string, ciphertext []byte) CompleteResult {
	t.Helper()
	revision := int64(0)
	session, err := s.Create(ctx, CreateInput{UserID: userID, DeviceID: deviceID, TargetNodeID: nodeID, FileVersionID: uuid.NewString(), BlobID: blobID, ExpectedRevision: &revision, ChunkSize: 100, ChunkCount: 1, MetadataKeyVersion: 1, MetadataCiphertext: []byte("m"), WrappedFileKey: []byte("k"), E2EEHeader: []byte("h")})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.PutChunk(ctx, userID, deviceID, session.ID, 0, ciphertext); err != nil {
		t.Fatal(err)
	}
	result, err := s.Complete(ctx, session.ID, CompleteInput{UserID: userID, DeviceID: deviceID, OperationID: uuid.NewString(), KeyScopeID: userID, KeyVersion: 1})
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func TestCreateRejectsAnAlreadyCommittedBlobID(t *testing.T) {
	ctx, db, s, dir, userID, deviceID, nodeID := newSecurityTestService(t)
	victim := uploadOneChunk(t, ctx, s, userID, deviceID, nodeID, uuid.NewString(), []byte("victim-ciphertext"))

	attackerNode := seedSecondFileNode(t, ctx, db, userID)
	revision := int64(0)
	_, err := s.Create(ctx, CreateInput{UserID: userID, DeviceID: deviceID, TargetNodeID: attackerNode, FileVersionID: uuid.NewString(), BlobID: victim.BlobID, ExpectedRevision: &revision, ChunkSize: 100, ChunkCount: 1, MetadataKeyVersion: 1, MetadataCiphertext: []byte("m"), WrappedFileKey: []byte("k"), E2EEHeader: []byte("h")})
	if !errors.Is(err, ErrIDConflict) {
		t.Fatalf("error=%v, want %v", err, ErrIDConflict)
	}
	assertBlobContent(t, dir, victim.BlobID, "victim-ciphertext")
}

// A session that already reuses a committed blob ID (for example one opened
// by an older server before IDs were reserved) must still never overwrite
// or delete the committed ciphertext when it completes.
func TestCompleteNeverReplacesAnotherVersionsBlob(t *testing.T) {
	ctx, db, s, dir, userID, deviceID, nodeID := newSecurityTestService(t)
	victim := uploadOneChunk(t, ctx, s, userID, deviceID, nodeID, uuid.NewString(), []byte("victim-ciphertext"))

	attackerNode := seedSecondFileNode(t, ctx, db, userID)
	revision := int64(0)
	session, err := s.Create(ctx, CreateInput{UserID: userID, DeviceID: deviceID, TargetNodeID: attackerNode, FileVersionID: uuid.NewString(), BlobID: uuid.NewString(), ExpectedRevision: &revision, ChunkSize: 100, ChunkCount: 1, MetadataKeyVersion: 1, MetadataCiphertext: []byte("m"), WrappedFileKey: []byte("k"), E2EEHeader: []byte("h")})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, "UPDATE upload_sessions SET blob_id=? WHERE id=?", victim.BlobID, session.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.PutChunk(ctx, userID, deviceID, session.ID, 0, []byte("attacker")); err != nil {
		t.Fatal(err)
	}
	_, err = s.Complete(ctx, session.ID, CompleteInput{UserID: userID, DeviceID: deviceID, OperationID: uuid.NewString(), KeyScopeID: userID, KeyVersion: 1})
	if !errors.Is(err, ErrIDConflict) {
		t.Fatalf("error=%v, want %v", err, ErrIDConflict)
	}
	assertBlobContent(t, dir, victim.BlobID, "victim-ciphertext")
}

func TestCompleteReplacesItsOwnCrashLeftover(t *testing.T) {
	ctx, _, s, dir, userID, deviceID, nodeID := newSecurityTestService(t)
	blobID := uuid.NewString()
	// A previous completion of this upload wrote the blob and then died
	// before its database transaction committed.
	if err := os.WriteFile(filepath.Join(dir, "blobs", blobID+".hbxblob"), []byte("torn"), 0o600); err != nil {
		t.Fatal(err)
	}
	uploadOneChunk(t, ctx, s, userID, deviceID, nodeID, blobID, []byte("complete-ciphertext"))
	assertBlobContent(t, dir, blobID, "complete-ciphertext")
}

func TestCreateBoundsChunkFraming(t *testing.T) {
	ctx, _, s, _, userID, deviceID, nodeID := newSecurityTestService(t)
	revision := int64(0)
	for _, framing := range []struct {
		name       string
		chunkSize  int64
		chunkCount int
	}{
		// 1-byte chunks within the total size cap previously made Complete
		// allocate bookkeeping for hundreds of millions of chunks.
		{"too many chunks", 1, maxChunkCount + 1},
		{"chunk larger than a request body", MaxChunkCiphertextSize + 1, 1},
	} {
		_, err := s.Create(ctx, CreateInput{UserID: userID, DeviceID: deviceID, TargetNodeID: nodeID, FileVersionID: uuid.NewString(), BlobID: uuid.NewString(), ExpectedRevision: &revision, ChunkSize: framing.chunkSize, ChunkCount: framing.chunkCount, MetadataKeyVersion: 1, MetadataCiphertext: []byte("m"), WrappedFileKey: []byte("k"), E2EEHeader: []byte("h")})
		var validation *apierror.Validation
		if !errors.As(err, &validation) {
			t.Fatalf("%s: error=%v, want a validation error", framing.name, err)
		}
	}
}

func TestPutChunkRejectsAChunkLargerThanDeclared(t *testing.T) {
	ctx, _, s, _, userID, deviceID, nodeID := newSecurityTestService(t)
	revision := int64(0)
	session, err := s.Create(ctx, CreateInput{UserID: userID, DeviceID: deviceID, TargetNodeID: nodeID, FileVersionID: uuid.NewString(), BlobID: uuid.NewString(), ExpectedRevision: &revision, ChunkSize: 4, ChunkCount: 2, MetadataKeyVersion: 1, MetadataCiphertext: []byte("m"), WrappedFileKey: []byte("k"), E2EEHeader: []byte("h")})
	if err != nil {
		t.Fatal(err)
	}
	var validation *apierror.Validation
	if err := s.PutChunk(ctx, userID, deviceID, session.ID, 0, []byte("12345")); !errors.As(err, &validation) {
		t.Fatalf("error=%v, want a validation error", err)
	}
}

func TestCreateRejectsNonCanonicalIDs(t *testing.T) {
	ctx, _, s, _, userID, deviceID, nodeID := newSecurityTestService(t)
	revision := int64(0)
	blobID := uuid.NewString()
	for _, spelling := range []string{"{" + blobID + "}", "urn:uuid:" + blobID, toUpper(blobID)} {
		_, err := s.Create(ctx, CreateInput{UserID: userID, DeviceID: deviceID, TargetNodeID: nodeID, FileVersionID: uuid.NewString(), BlobID: spelling, ExpectedRevision: &revision, ChunkSize: 4, ChunkCount: 1, MetadataKeyVersion: 1, MetadataCiphertext: []byte("m"), WrappedFileKey: []byte("k"), E2EEHeader: []byte("h")})
		var validation *apierror.Validation
		if !errors.As(err, &validation) {
			t.Fatalf("blob id %q: error=%v, want a validation error", spelling, err)
		}
	}
}

func TestCompleteRejectsAnOperationIDFromAnotherAccount(t *testing.T) {
	ctx, db, s, _, userID, deviceID, nodeID := newSecurityTestService(t)
	foreignOperation := uuid.NewString()
	now := time.Now().UTC().Format(time.RFC3339Nano)
	otherUser, otherDevice := uuid.NewString(), uuid.NewString()
	if _, err := db.ExecContext(ctx, `INSERT INTO users (id,username,username_norm,password_hash,role,status,created_at,updated_at) VALUES (?,?,?,'hash','USER','ACTIVE',?,?)`, otherUser, "other", "other", now, now); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `INSERT INTO devices (id,user_id,name,platform,e2ee_public_key,e2ee_key_version,created_at,last_seen_at) VALUES (?,?,?,'WINDOWS',?,1,?,?)`, otherDevice, otherUser, "device", []byte("key"), now, now); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `INSERT INTO processed_operations (operation_id,user_id,device_id,operation_type,result_code,result_payload,created_at,expires_at) VALUES (?,?,?,'UPLOAD_COMPLETE','OK',?,?,?)`,
		foreignOperation, otherUser, otherDevice, []byte(uuid.NewString()+":"+uuid.NewString()+":7"), now, now); err != nil {
		t.Fatal(err)
	}
	revision := int64(0)
	session, err := s.Create(ctx, CreateInput{UserID: userID, DeviceID: deviceID, TargetNodeID: nodeID, FileVersionID: uuid.NewString(), BlobID: uuid.NewString(), ExpectedRevision: &revision, ChunkSize: 100, ChunkCount: 1, MetadataKeyVersion: 1, MetadataCiphertext: []byte("m"), WrappedFileKey: []byte("k"), E2EEHeader: []byte("h")})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.PutChunk(ctx, userID, deviceID, session.ID, 0, []byte("c")); err != nil {
		t.Fatal(err)
	}
	_, err = s.Complete(ctx, session.ID, CompleteInput{UserID: userID, DeviceID: deviceID, OperationID: foreignOperation, KeyScopeID: userID, KeyVersion: 1})
	var validation *apierror.Validation
	if !errors.As(err, &validation) {
		t.Fatalf("error=%v, want a validation error instead of another account's result", err)
	}
}

func assertBlobContent(t *testing.T, dir, blobID, want string) {
	t.Helper()
	got, err := os.ReadFile(filepath.Join(dir, "blobs", blobID+".hbxblob"))
	if err != nil {
		t.Fatalf("blob %s: %v", blobID, err)
	}
	if string(got) != want {
		t.Fatalf("blob %s = %q, want %q", blobID, got, want)
	}
}

func toUpper(value string) string {
	out := []byte(value)
	for i, c := range out {
		if c >= 'a' && c <= 'f' {
			out[i] = c - 'a' + 'A'
		}
	}
	return string(out)
}

func TestCreateCapsOpenSessionsPerDevice(t *testing.T) {
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
	create := func() (Session, error) {
		return s.Create(ctx, CreateInput{UserID: userID, DeviceID: deviceID, TargetNodeID: nodeID, FileVersionID: uuid.NewString(), BlobID: uuid.NewString(),
			ExpectedRevision: &expectedRevision, ChunkSize: 10, ChunkCount: 1, MetadataKeyVersion: 1,
			MetadataCiphertext: []byte("m"), WrappedFileKey: []byte("k"), E2EEHeader: []byte("h")})
	}
	var first Session
	for i := 0; i < MaxOpenSessionsPerDevice; i++ {
		session, err := create()
		if err != nil {
			t.Fatalf("session %d: %v", i, err)
		}
		if i == 0 {
			first = session
		}
	}
	if _, err := create(); err != ErrTooManyUploads {
		t.Fatalf("error=%v, want %v", err, ErrTooManyUploads)
	}
	// An aborted session no longer holds temporary storage.
	if err := s.Abort(ctx, userID, deviceID, first.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := create(); err != nil {
		t.Fatalf("a slot freed by Abort must be reusable: %v", err)
	}
	// Abandoned sessions stop counting once they expire.
	s.now = func() time.Time { return time.Now().Add(2 * time.Hour) }
	if _, err := create(); err != nil {
		t.Fatalf("expired sessions must not count toward the cap: %v", err)
	}
}
