package uploads

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/homebox/homebox/internal/apierror"
)

var (
	ErrNotFound          = errors.New("upload session not found")
	ErrForbidden         = errors.New("upload session does not belong to this device")
	ErrInvalidState      = errors.New("upload session is not open")
	ErrChunkConflict     = errors.New("chunk already exists with a different ciphertext digest")
	ErrMissingChunks     = errors.New("upload has missing ciphertext chunks")
	ErrRevisionConflict  = errors.New("node revision conflict")
	ErrTargetNodeMissing = errors.New("target file node not found")
)

type Service struct {
	db                *sql.DB
	storagePath       string
	maxCiphertextSize int64
	abandonedAfter    time.Duration
	now               func() time.Time
	mu                sync.Mutex
}

type CreateInput struct {
	UserID, DeviceID, TargetNodeID, FileVersionID, BlobID string
	ExpectedRevision                                      *int64
	ChunkSize                                             int64
	ChunkCount                                            int
	MetadataCiphertext, WrappedFileKey, E2EEHeader        []byte
}

type Session struct {
	ID, BlobID, FileVersionID, Status string
	ChunkCount                        int
	ReceivedChunks                    []int
	ExpiresAt                         time.Time
}

type CompleteInput struct {
	UserID, DeviceID, OperationID, KeyScopeID string
	ExpectedRevision                          *int64
	KeyVersion                                int
	SyncPayloadCiphertext                     []byte
}

type CompleteResult struct {
	BlobID, FileVersionID string
	Revision              int64
}

func New(db *sql.DB, storagePath string, maxCiphertextSize int64, abandonedAfter time.Duration) (*Service, error) {
	if maxCiphertextSize <= 0 || abandonedAfter <= 0 {
		return nil, errors.New("invalid upload service limits")
	}
	for _, dir := range []string{filepath.Join(storagePath, "blobs"), filepath.Join(storagePath, "temp", "uploads")} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return nil, fmt.Errorf("create ciphertext storage: %w", err)
		}
	}
	return &Service{db: db, storagePath: storagePath, maxCiphertextSize: maxCiphertextSize, abandonedAfter: abandonedAfter, now: time.Now}, nil
}

func (s *Service) Create(ctx context.Context, in CreateInput) (Session, error) {
	if !validUUID(in.TargetNodeID) || !validUUID(in.FileVersionID) || !validUUID(in.BlobID) || in.ChunkCount < 1 || in.ChunkSize < 1 || in.ChunkSize > s.maxCiphertextSize {
		return Session{}, apierror.NewValidation("invalid opaque upload framing")
	}
	if len(in.WrappedFileKey) == 0 || len(in.E2EEHeader) == 0 || len(in.MetadataCiphertext) == 0 {
		return Session{}, apierror.NewValidation("encrypted metadata, wrapped file key, and E2EE header are required")
	}
	if err := s.validateActorAndTarget(ctx, in.UserID, in.DeviceID, in.TargetNodeID); err != nil {
		return Session{}, err
	}
	if int64(in.ChunkCount)*in.ChunkSize > s.maxCiphertextSize {
		return Session{}, apierror.NewValidation("ciphertext framing exceeds the configured file limit")
	}
	now := s.now().UTC()
	session := Session{ID: uuid.NewString(), BlobID: in.BlobID, FileVersionID: in.FileVersionID, Status: "OPEN", ChunkCount: in.ChunkCount, ExpiresAt: now.Add(s.abandonedAfter)}
	_, err := s.db.ExecContext(ctx, `INSERT INTO upload_sessions
		(id,user_id,device_id,target_node_id,file_version_id,blob_id,expected_revision,chunk_size,chunk_count,max_ciphertext_size,metadata_ciphertext,wrapped_file_key,e2ee_header,status,created_at,expires_at)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,'OPEN',?,?)`,
		session.ID, in.UserID, in.DeviceID, nullableString(in.TargetNodeID), in.FileVersionID, in.BlobID, nullableInt(in.ExpectedRevision), in.ChunkSize, in.ChunkCount, s.maxCiphertextSize,
		in.MetadataCiphertext, in.WrappedFileKey, in.E2EEHeader, now.Format(time.RFC3339Nano), session.ExpiresAt.Format(time.RFC3339Nano))
	if err != nil {
		return Session{}, fmt.Errorf("create upload session: %w", err)
	}
	if err := os.MkdirAll(s.uploadDir(session.ID), 0o700); err != nil {
		return Session{}, fmt.Errorf("create upload temp directory: %w", err)
	}
	return session, nil
}

func (s *Service) PutChunk(ctx context.Context, userID, deviceID, uploadID string, chunkNo int, ciphertext []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !validUUID(uploadID) || chunkNo < 0 || len(ciphertext) == 0 || int64(len(ciphertext)) > s.maxCiphertextSize {
		return apierror.NewValidation("invalid ciphertext chunk")
	}
	session, err := s.sessionForDevice(ctx, userID, deviceID, uploadID)
	if err != nil {
		return err
	}
	if session.Status != "OPEN" || !s.now().Before(session.ExpiresAt) {
		return ErrInvalidState
	}
	if chunkNo >= session.ChunkCount {
		return apierror.NewValidation("chunk number exceeds declared chunk count")
	}
	digest := sha256.Sum256(ciphertext)
	digestText := hex.EncodeToString(digest[:])
	var existingDigest string
	err = s.db.QueryRowContext(ctx, "SELECT ciphertext_sha256 FROM upload_chunks WHERE upload_id=? AND chunk_no=?", uploadID, chunkNo).Scan(&existingDigest)
	if err == nil {
		if existingDigest != digestText {
			return ErrChunkConflict
		}
		return nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	finalPath := filepath.Join(s.uploadDir(uploadID), strconv.Itoa(chunkNo)+".chunk")
	if err := writeAtomic(finalPath, ciphertext); err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `INSERT INTO upload_chunks (upload_id,chunk_no,ciphertext_size,ciphertext_sha256,temp_rel_path,received_at)
		VALUES (?,?,?,?,?,?) ON CONFLICT(upload_id,chunk_no) DO NOTHING`, uploadID, chunkNo, len(ciphertext), digestText,
		filepath.ToSlash(filepath.Join("temp", "uploads", uploadID, strconv.Itoa(chunkNo)+".chunk")), s.now().UTC().Format(time.RFC3339Nano))
	if err != nil {
		return fmt.Errorf("record ciphertext chunk: %w", err)
	}
	existingDigest = ""
	if err := s.db.QueryRowContext(ctx, "SELECT ciphertext_sha256 FROM upload_chunks WHERE upload_id=? AND chunk_no=?", uploadID, chunkNo).Scan(&existingDigest); err != nil {
		return err
	}
	if existingDigest != digestText {
		return ErrChunkConflict
	}
	return nil
}

func (s *Service) Get(ctx context.Context, userID, deviceID, uploadID string) (Session, error) {
	session, err := s.sessionForDevice(ctx, userID, deviceID, uploadID)
	if err != nil {
		return Session{}, err
	}
	rows, err := s.db.QueryContext(ctx, "SELECT chunk_no FROM upload_chunks WHERE upload_id=? ORDER BY chunk_no", uploadID)
	if err != nil {
		return Session{}, err
	}
	defer rows.Close()
	for rows.Next() {
		var n int
		if err := rows.Scan(&n); err != nil {
			return Session{}, err
		}
		session.ReceivedChunks = append(session.ReceivedChunks, n)
	}
	return session.Session, rows.Err()
}

// Abort cancels an open upload session and deletes its temporary ciphertext
// chunks. Aborting an already-completed or already-aborted session is a
// no-op rather than an error, so a client retrying a DELETE after a network
// blip doesn't need special-case handling.
func (s *Service) Abort(ctx context.Context, userID, deviceID, uploadID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	session, err := s.sessionForDevice(ctx, userID, deviceID, uploadID)
	if err != nil {
		return err
	}
	if session.Status != "OPEN" {
		return nil
	}
	if _, err := s.db.ExecContext(ctx, "UPDATE upload_sessions SET status='ABORTED' WHERE id=?", uploadID); err != nil {
		return fmt.Errorf("abort upload session: %w", err)
	}
	return os.RemoveAll(s.uploadDir(uploadID))
}

// OpenBlob resolves a FileVersion to the absolute path of its immutable
// ciphertext blob, for streaming on download (spec §23). Callers must
// authorize access to the owning node themselves first (see
// internal/nodes.Service.Get) — this performs no authorization of its own.
func (s *Service) OpenBlob(ctx context.Context, fileVersionID string) (path string, size int64, err error) {
	var relPath string
	err = s.db.QueryRowContext(ctx, `SELECT b.storage_rel_path, b.ciphertext_size
		FROM file_versions f JOIN blobs b ON b.id = f.blob_id WHERE f.id = ?`, fileVersionID).Scan(&relPath, &size)
	if errors.Is(err, sql.ErrNoRows) {
		return "", 0, ErrNotFound
	}
	if err != nil {
		return "", 0, err
	}
	return filepath.Join(s.storagePath, filepath.FromSlash(relPath)), size, nil
}

func (s *Service) Complete(ctx context.Context, uploadID string, in CompleteInput) (CompleteResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !validUUID(uploadID) || !validUUID(in.OperationID) || in.KeyScopeID == "" || in.KeyVersion < 1 {
		return CompleteResult{}, apierror.NewValidation("invalid opaque completion request")
	}
	session, err := s.sessionForDevice(ctx, in.UserID, in.DeviceID, uploadID)
	if err != nil {
		return CompleteResult{}, err
	}
	if session.Status == "COMPLETED" {
		return s.completedResult(ctx, session.FileVersionID)
	}
	if session.Status != "OPEN" || !s.now().Before(session.ExpiresAt) {
		return CompleteResult{}, ErrInvalidState
	}
	var existingResult []byte
	err = s.db.QueryRowContext(ctx, "SELECT result_payload FROM processed_operations WHERE operation_id=?", in.OperationID).Scan(&existingResult)
	if err == nil {
		return decodeResult(existingResult)
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return CompleteResult{}, err
	}
	chunks, totalSize, err := s.loadChunks(ctx, uploadID, session.ChunkCount)
	if err != nil {
		return CompleteResult{}, err
	}
	if totalSize > s.maxCiphertextSize {
		return CompleteResult{}, apierror.NewValidation("ciphertext exceeds configured file limit")
	}
	blobPath := filepath.Join(s.storagePath, "blobs", session.BlobID+".hbxblob")
	digest, err := s.assembleCiphertext(blobPath, chunks)
	if err != nil {
		return CompleteResult{}, err
	}
	removeOrphanBlob := true
	defer func() {
		if removeOrphanBlob {
			_ = os.Remove(blobPath)
		}
	}()

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return CompleteResult{}, err
	}
	defer tx.Rollback()
	if err := tx.QueryRowContext(ctx, "SELECT result_payload FROM processed_operations WHERE operation_id=?", in.OperationID).Scan(&existingResult); err == nil {
		return decodeResult(existingResult)
	} else if !errors.Is(err, sql.ErrNoRows) {
		return CompleteResult{}, err
	}
	var ownerID string
	var currentRevision int64
	if err := tx.QueryRowContext(ctx, "SELECT owner_id,revision FROM nodes WHERE id=? AND node_type='FILE' AND deleted_at IS NULL", session.targetNodeID).Scan(&ownerID, &currentRevision); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return CompleteResult{}, ErrTargetNodeMissing
		}
		return CompleteResult{}, err
	}
	if ownerID != in.UserID {
		return CompleteResult{}, ErrForbidden
	}
	if in.ExpectedRevision != nil && currentRevision != *in.ExpectedRevision {
		return CompleteResult{}, ErrRevisionConflict
	}
	now := s.now().UTC().Format(time.RFC3339Nano)
	relPath := filepath.ToSlash(filepath.Join("blobs", session.BlobID+".hbxblob"))
	if _, err := tx.ExecContext(ctx, `INSERT INTO blobs (id,ciphertext_size,storage_rel_path,ciphertext_sha256,format_version,chunk_count,created_at) VALUES (?,?,?,?,1,?,?)`, session.BlobID, totalSize, relPath, digest, session.ChunkCount, now); err != nil {
		return CompleteResult{}, fmt.Errorf("create blob record: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO sync_changes (user_scope_id,node_id,operation,payload_ciphertext,created_at) VALUES (?,?, 'UPDATE', ?, ?)`, in.UserID, session.targetNodeID, in.SyncPayloadCiphertext, now); err != nil {
		return CompleteResult{}, err
	}
	var revision int64
	if err := tx.QueryRowContext(ctx, "SELECT last_insert_rowid()").Scan(&revision); err != nil {
		return CompleteResult{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO file_versions (id,node_id,blob_id,e2ee_header,wrapped_file_key,key_scope_id,key_version,created_at,created_by_device_id,revision) VALUES (?,?,?,?,?,?,?,?,?,?)`, session.FileVersionID, session.targetNodeID, session.BlobID, session.e2eeHeader, session.wrappedFileKey, in.KeyScopeID, in.KeyVersion, now, in.DeviceID, revision); err != nil {
		return CompleteResult{}, err
	}
	if _, err := tx.ExecContext(ctx, "UPDATE nodes SET current_version_id=?,revision=?,updated_at=? WHERE id=?", session.FileVersionID, revision, now, session.targetNodeID); err != nil {
		return CompleteResult{}, err
	}
	result := CompleteResult{BlobID: session.BlobID, FileVersionID: session.FileVersionID, Revision: revision}
	payload := []byte(result.BlobID + ":" + result.FileVersionID + ":" + strconv.FormatInt(result.Revision, 10))
	if _, err := tx.ExecContext(ctx, `INSERT INTO processed_operations (operation_id,user_id,device_id,operation_type,result_code,result_payload,created_at,expires_at) VALUES (?,?,?,'UPLOAD_COMPLETE','OK',?,?,?)`, in.OperationID, in.UserID, in.DeviceID, payload, now, s.now().Add(30*24*time.Hour).UTC().Format(time.RFC3339Nano)); err != nil {
		return CompleteResult{}, err
	}
	if _, err := tx.ExecContext(ctx, "UPDATE upload_sessions SET status='COMPLETED',completed_at=? WHERE id=?", now, uploadID); err != nil {
		return CompleteResult{}, err
	}
	if err := tx.Commit(); err != nil {
		return CompleteResult{}, err
	}
	removeOrphanBlob = false
	if err := os.RemoveAll(s.uploadDir(uploadID)); err != nil {
		return CompleteResult{}, fmt.Errorf("ciphertext committed but temporary cleanup failed: %w", err)
	}
	return result, nil
}

type dbSession struct {
	Session
	targetNodeID   string
	e2eeHeader     []byte
	wrappedFileKey []byte
}

func (s *Service) sessionForDevice(ctx context.Context, userID, deviceID, uploadID string) (dbSession, error) {
	var r dbSession
	var expires string
	err := s.db.QueryRowContext(ctx, `SELECT id,blob_id,file_version_id,status,chunk_count,expires_at,target_node_id,e2ee_header,wrapped_file_key FROM upload_sessions WHERE id=? AND user_id=? AND device_id=?`, uploadID, userID, deviceID).Scan(&r.ID, &r.BlobID, &r.FileVersionID, &r.Status, &r.ChunkCount, &expires, &r.targetNodeID, &r.e2eeHeader, &r.wrappedFileKey)
	if errors.Is(err, sql.ErrNoRows) {
		return r, ErrNotFound
	}
	if err != nil {
		return r, err
	}
	r.ExpiresAt, err = time.Parse(time.RFC3339Nano, expires)
	return r, err
}

func (s *Service) validateActorAndTarget(ctx context.Context, userID, deviceID, nodeID string) error {
	var deviceCount int
	if err := s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM devices WHERE id=? AND user_id=? AND revoked_at IS NULL", deviceID, userID).Scan(&deviceCount); err != nil {
		return err
	}
	if deviceCount != 1 {
		return ErrForbidden
	}
	var ownerID string
	if err := s.db.QueryRowContext(ctx, "SELECT owner_id FROM nodes WHERE id=? AND node_type='FILE' AND deleted_at IS NULL", nodeID).Scan(&ownerID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrTargetNodeMissing
		}
		return err
	}
	if ownerID != userID {
		return ErrForbidden
	}
	return nil
}

type ciphertextChunk struct{ relativePath, digest string }

func (s *Service) loadChunks(ctx context.Context, uploadID string, count int) ([]ciphertextChunk, int64, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT chunk_no,temp_rel_path,ciphertext_size,ciphertext_sha256 FROM upload_chunks WHERE upload_id=?", uploadID)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	paths := make([]ciphertextChunk, count)
	var total int64
	for rows.Next() {
		var no int
		var path, digest string
		var size int64
		if err := rows.Scan(&no, &path, &size, &digest); err != nil {
			return nil, 0, err
		}
		if no < 0 || no >= count {
			return nil, 0, ErrMissingChunks
		}
		expectedPath := filepath.ToSlash(filepath.Join("temp", "uploads", uploadID, strconv.Itoa(no)+".chunk"))
		if path != expectedPath {
			return nil, 0, errors.New("invalid ciphertext chunk storage path")
		}
		paths[no] = ciphertextChunk{relativePath: path, digest: digest}
		total += size
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	for _, p := range paths {
		if p.relativePath == "" {
			return nil, 0, ErrMissingChunks
		}
	}
	return paths, total, nil
}
func (s *Service) assembleCiphertext(destination string, chunks []ciphertextChunk) (string, error) {
	partial := destination + ".partial"
	f, err := os.OpenFile(partial, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return "", err
	}
	cleanup := true
	defer func() {
		f.Close()
		if cleanup {
			os.Remove(partial)
		}
	}()
	h := sha256.New()
	for _, chunk := range chunks {
		absolute := filepath.Join(s.storagePath, filepath.FromSlash(chunk.relativePath))
		in, err := os.Open(absolute)
		if err != nil {
			return "", err
		}
		chunkHash := sha256.New()
		_, copyErr := io.Copy(io.MultiWriter(f, h, chunkHash), in)
		closeErr := in.Close()
		if copyErr != nil {
			return "", copyErr
		}
		if closeErr != nil {
			return "", closeErr
		}
		if hex.EncodeToString(chunkHash.Sum(nil)) != chunk.digest {
			return "", errors.New("stored ciphertext chunk digest mismatch")
		}
	}
	if err := f.Sync(); err != nil {
		return "", err
	}
	if err := f.Close(); err != nil {
		return "", err
	}
	if err := os.Rename(partial, destination); err != nil {
		return "", err
	}
	cleanup = false
	return hex.EncodeToString(h.Sum(nil)), nil
}
func (s *Service) completedResult(ctx context.Context, versionID string) (CompleteResult, error) {
	var r CompleteResult
	err := s.db.QueryRowContext(ctx, `SELECT b.id,f.id,f.revision FROM file_versions f JOIN blobs b ON b.id=f.blob_id WHERE f.id=?`, versionID).Scan(&r.BlobID, &r.FileVersionID, &r.Revision)
	return r, err
}
func (s *Service) uploadDir(id string) string {
	return filepath.Join(s.storagePath, "temp", "uploads", id)
}
func writeAtomic(path string, data []byte) error {
	temp := path + ".new"
	if err := os.WriteFile(temp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(temp, path)
}
func validUUID(value string) bool { _, err := uuid.Parse(value); return err == nil }
func nullableString(v string) any {
	if v == "" {
		return nil
	}
	return v
}
func nullableInt(v *int64) any {
	if v == nil {
		return nil
	}
	return *v
}
func decodeResult(v []byte) (CompleteResult, error) {
	fields := strings.Split(string(v), ":")
	if len(fields) != 3 || !validUUID(fields[0]) || !validUUID(fields[1]) {
		return CompleteResult{}, errors.New("invalid stored operation result")
	}
	revision, err := strconv.ParseInt(fields[2], 10, 64)
	return CompleteResult{BlobID: fields[0], FileVersionID: fields[1], Revision: revision}, err
}
