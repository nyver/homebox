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

// Result reports exactly what an automatic or manually invoked pass removed.
type Result struct {
	ExpiredUploads       int
	ExpiredAccessTokens  int64
	ExpiredRefreshTokens int64
	ExpiredOperations    int64
	ExpiredTrashItems    int
	PrunedFileVersions   int64
	UnreferencedBlobs    int
	OrphanBlobFiles      int
}

// Policy configures how long maintenance keeps reclaimable server state.
type Policy struct {
	// OrphanBlobGrace is how long ciphertext must stay unreachable before
	// a second pass may delete it.
	OrphanBlobGrace time.Duration
	// TrashRetention is how long a soft-deleted node stays restorable.
	TrashRetention time.Duration
	// MaxFileVersions bounds the versions kept per file, current included.
	MaxFileVersions int
	// VersionRetention removes non-current versions older than this even
	// when fewer than MaxFileVersions exist.
	VersionRetention time.Duration
}

type Service struct {
	db          *sql.DB
	storagePath string
	policy      Policy
	now         func() time.Time
}

func New(db *sql.DB, storagePath string, policy Policy) (*Service, error) {
	if db == nil || storagePath == "" {
		return nil, errors.New("database and storage path are required")
	}
	if policy.OrphanBlobGrace <= 0 || policy.TrashRetention <= 0 || policy.MaxFileVersions < 1 || policy.VersionRetention <= 0 {
		return nil, errors.New("maintenance policy durations and version limit must be positive")
	}
	return &Service{
		db:          db,
		storagePath: storagePath,
		policy:      policy,
		now:         time.Now,
	}, nil
}

// Run safely reclaims expired control-plane records and Trash subtrees, then
// removes ciphertext that has been unreachable for the configured grace
// period. It never decrypts content or removes a blob referenced by a version.
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
	trashItems, err := s.cleanupExpiredTrash(ctx, now)
	if err != nil {
		return Result{}, err
	}
	result.ExpiredTrashItems = trashItems
	if result.PrunedFileVersions, err = s.pruneFileVersions(ctx, now); err != nil {
		return Result{}, err
	}
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

const trashSubtreeCTE = `WITH RECURSIVE subtree(id,owner_id) AS (
	SELECT id,owner_id FROM nodes WHERE id=? AND deleted_at <= ?
	UNION
	SELECT n.id,n.owner_id FROM nodes n JOIN subtree s ON n.parent_id=s.id AND n.owner_id=s.owner_id
) `

// cleanupExpiredTrash permanently removes each expired Trash entry and its
// complete subtree in one transaction. Blob rows deliberately remain: once
// their file versions are gone, the existing two-pass GC safely reclaims them.
func (s *Service) cleanupExpiredTrash(ctx context.Context, now time.Time) (int, error) {
	cutoff := now.Add(-s.policy.TrashRetention).Format(time.RFC3339Nano)
	rows, err := s.db.QueryContext(ctx, "SELECT id FROM nodes WHERE deleted_at <= ? ORDER BY deleted_at", cutoff)
	if err != nil {
		return 0, fmt.Errorf("list expired Trash entries: %w", err)
	}
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return 0, err
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, err
	}
	if err := rows.Close(); err != nil {
		return 0, err
	}

	deleted := 0
	for _, id := range ids {
		purged, err := s.purgeSubtree(ctx, id, cutoff, now)
		if err != nil {
			return 0, err
		}
		if purged {
			deleted++
		}
	}
	return deleted, nil
}

// ErrNotInTrash is returned when a permanent delete targets a node that is
// not (or no longer) in its owner's Trash.
var ErrNotInTrash = errors.New("node is not in this account's trash")

// PurgeTrashEntry permanently deletes one of ownerID's Trash entries and
// its whole subtree right away instead of after the retention period, with
// exactly the same cleanup as the scheduled purge. Its ciphertext goes
// through the normal two-pass blob GC.
func (s *Service) PurgeTrashEntry(ctx context.Context, ownerID, nodeID string) error {
	var owner string
	var deletedAt sql.NullString
	err := s.db.QueryRowContext(ctx, "SELECT owner_id,deleted_at FROM nodes WHERE id=?", nodeID).Scan(&owner, &deletedAt)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && (owner != ownerID || !deletedAt.Valid)) {
		return ErrNotInTrash
	}
	if err != nil {
		return err
	}
	now := s.now().UTC()
	// The node's own deletion time as the cutoff keeps the CTE's
	// "in Trash" condition true for exactly this entry.
	purged, err := s.purgeSubtree(ctx, nodeID, deletedAt.String, now)
	if err != nil {
		return err
	}
	if !purged {
		return ErrNotInTrash
	}
	return nil
}

// purgeSubtree permanently removes Trash entry id (deleted at or before
// cutoff) and its complete subtree in one transaction. Blob rows
// deliberately remain: once their file versions are gone, the existing
// two-pass GC safely reclaims them. It reports whether anything was removed.
func (s *Service) purgeSubtree(ctx context.Context, id, cutoff string, now time.Time) (bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	uploadRows, err := tx.QueryContext(ctx, trashSubtreeCTE+`SELECT u.id FROM upload_sessions u
		WHERE u.target_node_id IN (SELECT id FROM subtree)`, id, cutoff)
	if err != nil {
		return false, fmt.Errorf("list Trash uploads: %w", err)
	}
	var uploadIDs []string
	for uploadRows.Next() {
		var uploadID string
		if err := uploadRows.Scan(&uploadID); err != nil {
			uploadRows.Close()
			return false, err
		}
		if _, err := uuid.Parse(uploadID); err != nil {
			uploadRows.Close()
			return false, fmt.Errorf("invalid upload ID in Trash subtree: %w", err)
		}
		uploadIDs = append(uploadIDs, uploadID)
	}
	if err := uploadRows.Err(); err != nil {
		uploadRows.Close()
		return false, err
	}
	if err := uploadRows.Close(); err != nil {
		return false, err
	}
	if _, err := tx.ExecContext(ctx, trashSubtreeCTE+`INSERT INTO sync_changes
		(user_scope_id,node_id,operation,created_at)
		SELECT owner_id,id,'PURGE',? FROM subtree`, id, cutoff, now.Format(time.RFC3339Nano)); err != nil {
		return false, fmt.Errorf("record Trash purge sync changes: %w", err)
	}
	queries := []struct {
		name string
		sql  string
	}{
		// A folder key is removed only once nothing outside the purged
		// subtree is still encrypted under it: a node moved out of a
		// shared folder keeps that folder's key scope.
		{"folder keys", trashSubtreeCTE + `DELETE FROM folder_keys WHERE folder_id IN (SELECT id FROM subtree)
			AND NOT EXISTS(SELECT 1 FROM nodes n WHERE n.metadata_key_scope_id=folder_keys.folder_id AND n.id NOT IN (SELECT id FROM subtree))
			AND NOT EXISTS(SELECT 1 FROM file_versions f WHERE f.key_scope_id=folder_keys.folder_id AND f.node_id NOT IN (SELECT id FROM subtree))`},
		{"share device envelopes", trashSubtreeCTE + `DELETE FROM share_device_envelopes
			WHERE share_id IN (SELECT id FROM shares WHERE node_id IN (SELECT id FROM subtree))`},
		{"shares", trashSubtreeCTE + "DELETE FROM shares WHERE node_id IN (SELECT id FROM subtree)"},
		{"favorites", trashSubtreeCTE + "DELETE FROM favorites WHERE node_id IN (SELECT id FROM subtree)"},
		{"upload chunks", trashSubtreeCTE + `DELETE FROM upload_chunks WHERE upload_id IN
			(SELECT id FROM upload_sessions WHERE target_node_id IN (SELECT id FROM subtree))`},
		{"upload sessions", trashSubtreeCTE + "DELETE FROM upload_sessions WHERE target_node_id IN (SELECT id FROM subtree)"},
		{"file versions", trashSubtreeCTE + "DELETE FROM file_versions WHERE node_id IN (SELECT id FROM subtree)"},
	}
	for _, query := range queries {
		if _, err := tx.ExecContext(ctx, query.sql, id, cutoff); err != nil {
			return false, fmt.Errorf("delete Trash %s: %w", query.name, err)
		}
	}
	for _, uploadID := range uploadIDs {
		if err := os.RemoveAll(s.uploadDir(uploadID)); err != nil {
			return false, fmt.Errorf("remove Trash upload ciphertext: %w", err)
		}
	}
	result, err := tx.ExecContext(ctx, trashSubtreeCTE+"DELETE FROM nodes WHERE id IN (SELECT id FROM subtree)", id, cutoff)
	if err != nil {
		return false, fmt.Errorf("delete Trash nodes: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	count, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	return count > 0, nil
}

// pruneFileVersions applies the version retention policy (spec §27.1). A
// file's current version is never a candidate; among the others, the newest
// MaxFileVersions-1 are kept unless they are older than VersionRetention.
// Only version records are removed here: their ciphertext then becomes
// unreferenced and goes through the same two-pass blob GC as Trash purges.
func (s *Service) pruneFileVersions(ctx context.Context, now time.Time) (int64, error) {
	result, err := s.db.ExecContext(ctx, `DELETE FROM file_versions WHERE id IN (
		SELECT id FROM (
			SELECT f.id, f.created_at,
				ROW_NUMBER() OVER (PARTITION BY f.node_id ORDER BY f.created_at DESC, f.id DESC) AS older_rank
			FROM file_versions f JOIN nodes n ON n.id = f.node_id
			WHERE n.current_version_id IS NOT NULL AND f.id != n.current_version_id
		) WHERE older_rank >= ? OR created_at < ?
	)`, s.policy.MaxFileVersions, now.Add(-s.policy.VersionRetention).Format(time.RFC3339Nano))
	if err != nil {
		return 0, fmt.Errorf("prune old file versions: %w", err)
	}
	return result.RowsAffected()
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
		WHERE c.marked_at <= ? AND NOT EXISTS (SELECT 1 FROM file_versions f WHERE f.blob_id=b.id)`, now.Add(-s.policy.OrphanBlobGrace).Format(time.RFC3339Nano))
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
	rows, err := s.db.QueryContext(ctx, "SELECT storage_rel_path FROM gc_orphan_blob_files WHERE marked_at <= ?", now.Add(-s.policy.OrphanBlobGrace).Format(time.RFC3339Nano))
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
