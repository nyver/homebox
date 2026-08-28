// Package maintenance removes expired server state without accessing E2EE plaintext.
package maintenance

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Result reports exactly what a manually invoked maintenance pass removed.
type Result struct {
	ExpiredUploads       int
	ExpiredAccessTokens  int64
	ExpiredRefreshTokens int64
	ExpiredOperations    int64
	UnreferencedBlobs    int
	OrphanBlobFiles      int
}

type Service struct {
	db          *sql.DB
	storagePath string
	gracePeriod time.Duration
	now         func() time.Time
}

func New(db *sql.DB, storagePath string, gracePeriod time.Duration) (*Service, error) {
	if db == nil || storagePath == "" || gracePeriod <= 0 {
		return nil, errors.New("database, storage path, and positive grace period are required")
	}
	return &Service{db: db, storagePath: storagePath, gracePeriod: gracePeriod, now: time.Now}, nil
}

// Run safely reclaims only expired control-plane records and ciphertext that
// has been unreachable for the whole configured grace period. It never
// deletes a file version, Trash node, or any blob referenced by a version.
func (s *Service) Run(ctx context.Context) (Result, error) {
	now := s.now().UTC()
	result, err := s.cleanupExpired(ctx, now)
	if err != nil {
		return Result{}, err
	}
	uploads, err := s.cleanupExpiredUploads(ctx, now)
	if err != nil {
		return Result{}, err
	}
	result.ExpiredUploads = uploads
	unreferenced, err := s.collectUnreferencedBlobs(ctx, now)
	if err != nil {
		return Result{}, err
	}
	result.UnreferencedBlobs = unreferenced
	orphanFiles, err := s.collectOrphanBlobFiles(ctx, now)
	if err != nil {
		return Result{}, err
	}
	result.OrphanBlobFiles = orphanFiles
	return result, nil
}

func (s *Service) cleanupExpired(ctx context.Context, now time.Time) (Result, error) {
	result := Result{}
	var err error
	if result.ExpiredAccessTokens, err = deleteBefore(ctx, s.db, "DELETE FROM access_tokens WHERE expires_at <= ?", now); err != nil {
		return Result{}, fmt.Errorf("delete expired access tokens: %w", err)
	}
	if result.ExpiredRefreshTokens, err = deleteBefore(ctx, s.db, "DELETE FROM refresh_tokens WHERE expires_at <= ?", now); err != nil {
		return Result{}, fmt.Errorf("delete expired refresh tokens: %w", err)
	}
	if result.ExpiredOperations, err = deleteBefore(ctx, s.db, "DELETE FROM processed_operations WHERE expires_at <= ?", now); err != nil {
		return Result{}, fmt.Errorf("delete expired idempotency operations: %w", err)
	}
	return result, nil
}

func deleteBefore(ctx context.Context, db *sql.DB, query string, now time.Time) (int64, error) {
	result, err := db.ExecContext(ctx, query, now.Format(time.RFC3339Nano))
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func (s *Service) cleanupExpiredUploads(ctx context.Context, now time.Time) (int, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id FROM upload_sessions
		WHERE expires_at <= ? AND status != 'COMPLETED'`, now.Format(time.RFC3339Nano))
	if err != nil {
		return 0, fmt.Errorf("list expired uploads: %w", err)
	}
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return 0, err
		}
		if _, err := uuid.Parse(id); err != nil {
			rows.Close()
			return 0, fmt.Errorf("invalid upload ID in database: %w", err)
		}
		ids = append(ids, id)
	}
	if err := rows.Close(); err != nil {
		return 0, err
	}
	cleaned := 0
	for _, id := range ids {
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return 0, err
		}
		expired, err := tx.ExecContext(ctx, `UPDATE upload_sessions SET status='EXPIRED'
			WHERE id=? AND expires_at <= ? AND status != 'COMPLETED'`, id, now.Format(time.RFC3339Nano))
		if err != nil {
			tx.Rollback()
			return 0, fmt.Errorf("expire upload session: %w", err)
		}
		if err := tx.Commit(); err != nil {
			return 0, err
		}
		count, err := expired.RowsAffected()
		if err != nil {
			return 0, err
		}
		if count == 0 {
			continue
		}
		if err := os.RemoveAll(s.uploadDir(id)); err != nil {
			return 0, fmt.Errorf("remove expired upload ciphertext: %w", err)
		}
		tx, err = s.db.BeginTx(ctx, nil)
		if err != nil {
			return 0, err
		}
		if _, err := tx.ExecContext(ctx, "DELETE FROM upload_chunks WHERE upload_id=?", id); err != nil {
			tx.Rollback()
			return 0, fmt.Errorf("delete expired upload chunks: %w", err)
		}
		if _, err := tx.ExecContext(ctx, "DELETE FROM upload_sessions WHERE id=? AND status='EXPIRED'", id); err != nil {
			tx.Rollback()
			return 0, fmt.Errorf("delete expired upload session: %w", err)
		}
		if err := tx.Commit(); err != nil {
			return 0, err
		}
		cleaned++
	}
	return cleaned, nil
}

func (s *Service) collectUnreferencedBlobs(ctx context.Context, now time.Time) (int, error) {
	if _, err := s.db.ExecContext(ctx, `INSERT INTO gc_blob_candidates (blob_id,marked_at)
		SELECT b.id, ? FROM blobs b
		WHERE NOT EXISTS (SELECT 1 FROM file_versions f WHERE f.blob_id=b.id)
		ON CONFLICT(blob_id) DO NOTHING`, now.Format(time.RFC3339Nano)); err != nil {
		return 0, fmt.Errorf("mark unreferenced blobs: %w", err)
	}
	if _, err := s.db.ExecContext(ctx, `DELETE FROM gc_blob_candidates
		WHERE NOT EXISTS (SELECT 1 FROM blobs b WHERE b.id=gc_blob_candidates.blob_id)
		OR EXISTS (SELECT 1 FROM file_versions f WHERE f.blob_id=gc_blob_candidates.blob_id)`); err != nil {
		return 0, fmt.Errorf("clear reachable blob candidates: %w", err)
	}
	rows, err := s.db.QueryContext(ctx, `SELECT c.blob_id,b.storage_rel_path FROM gc_blob_candidates c
		JOIN blobs b ON b.id=c.blob_id
		WHERE c.marked_at <= ? AND NOT EXISTS (SELECT 1 FROM file_versions f WHERE f.blob_id=b.id)`, now.Add(-s.gracePeriod).Format(time.RFC3339Nano))
	if err != nil {
		return 0, fmt.Errorf("list eligible blob candidates: %w", err)
	}
	defer rows.Close()
	type candidate struct{ id, path string }
	var candidates []candidate
	for rows.Next() {
		var c candidate
		if err := rows.Scan(&c.id, &c.path); err != nil {
			return 0, err
		}
		if !safeBlobPath(c.path) {
			return 0, fmt.Errorf("unsafe blob path in database: %q", c.path)
		}
		candidates = append(candidates, c)
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	deleted := 0
	for _, candidate := range candidates {
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return 0, err
		}
		if _, err := tx.ExecContext(ctx, "DELETE FROM gc_blob_candidates WHERE blob_id=?", candidate.id); err != nil {
			tx.Rollback()
			return 0, fmt.Errorf("clear blob candidate: %w", err)
		}
		result, err := tx.ExecContext(ctx, `DELETE FROM blobs
			WHERE id=? AND NOT EXISTS (SELECT 1 FROM file_versions WHERE blob_id=?)`, candidate.id, candidate.id)
		if err != nil {
			tx.Rollback()
			return 0, fmt.Errorf("delete unreachable blob record: %w", err)
		}
		if err := tx.Commit(); err != nil {
			return 0, err
		}
		affected, err := result.RowsAffected()
		if err != nil {
			return 0, err
		}
		if affected == 0 {
			continue
		}
		if err := os.Remove(filepath.Join(s.storagePath, filepath.FromSlash(candidate.path))); err != nil && !errors.Is(err, os.ErrNotExist) {
			return 0, fmt.Errorf("remove unreachable ciphertext blob: %w", err)
		}
		deleted++
	}
	return deleted, nil
}

func (s *Service) collectOrphanBlobFiles(ctx context.Context, now time.Time) (int, error) {
	entries, err := os.ReadDir(filepath.Join(s.storagePath, "blobs"))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return 0, nil
		}
		return 0, fmt.Errorf("read ciphertext blob directory: %w", err)
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".hbxblob") {
			continue
		}
		relativePath := "blobs/" + entry.Name()
		if !safeBlobPath(relativePath) {
			continue
		}
		var exists bool
		if err := s.db.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM blobs WHERE storage_rel_path=?)", relativePath).Scan(&exists); err != nil {
			return 0, err
		}
		if exists {
			if _, err := s.db.ExecContext(ctx, "DELETE FROM gc_orphan_blob_files WHERE storage_rel_path=?", relativePath); err != nil {
				return 0, err
			}
			continue
		}
		if _, err := s.db.ExecContext(ctx, `INSERT INTO gc_orphan_blob_files (storage_rel_path,marked_at) VALUES (?,?)
			ON CONFLICT(storage_rel_path) DO NOTHING`, relativePath, now.Format(time.RFC3339Nano)); err != nil {
			return 0, fmt.Errorf("mark orphan ciphertext blob: %w", err)
		}
	}
	rows, err := s.db.QueryContext(ctx, "SELECT storage_rel_path FROM gc_orphan_blob_files WHERE marked_at <= ?", now.Add(-s.gracePeriod).Format(time.RFC3339Nano))
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	var paths []string
	for rows.Next() {
		var path string
		if err := rows.Scan(&path); err != nil {
			return 0, err
		}
		if !safeBlobPath(path) {
			return 0, fmt.Errorf("unsafe orphan blob path in database: %q", path)
		}
		paths = append(paths, path)
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	deleted := 0
	for _, path := range paths {
		var exists bool
		if err := s.db.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM blobs WHERE storage_rel_path=?)", path).Scan(&exists); err != nil {
			return 0, err
		}
		if exists {
			if _, err := s.db.ExecContext(ctx, "DELETE FROM gc_orphan_blob_files WHERE storage_rel_path=?", path); err != nil {
				return 0, err
			}
			continue
		}
		if err := os.Remove(filepath.Join(s.storagePath, filepath.FromSlash(path))); err != nil && !errors.Is(err, os.ErrNotExist) {
			return 0, fmt.Errorf("remove orphan ciphertext blob: %w", err)
		}
		if _, err := s.db.ExecContext(ctx, "DELETE FROM gc_orphan_blob_files WHERE storage_rel_path=?", path); err != nil {
			return 0, err
		}
		deleted++
	}
	return deleted, nil
}

func (s *Service) uploadDir(id string) string {
	return filepath.Join(s.storagePath, "temp", "uploads", id)
}

func safeBlobPath(path string) bool {
	if !strings.HasPrefix(path, "blobs/") || strings.Count(path, "/") != 1 || !strings.HasSuffix(path, ".hbxblob") {
		return false
	}
	_, err := uuid.Parse(strings.TrimSuffix(strings.TrimPrefix(path, "blobs/"), ".hbxblob"))
	return err == nil
}
