// Package nodes implements opaque node CRUD (spec §17.3): create, read,
// rename/move, soft delete, and restore. Node identity is the opaque
// node_id (ADR-004); the server never inspects filenames because they live
// only inside client-encrypted metadata_ciphertext. Every mutation follows
// the same idempotency (ADR-006) and global-revision (ADR-005) patterns
// already established by internal/uploads.
package nodes

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/homebox/homebox/internal/apierror"
)

var (
	ErrNotFound         = errors.New("node not found")
	ErrForbidden        = errors.New("node does not belong to this account")
	ErrRevisionConflict = errors.New("node revision conflict")
	ErrInvalidParent    = errors.New("parent must be an existing, non-deleted directory owned by this account")
)

type Node struct {
	ID                 string
	OwnerID            string
	ParentID           *string
	NodeType           string // FILE | DIRECTORY
	MetadataCiphertext []byte
	MetadataKeyVersion int
	CurrentVersionID   *string
	Revision           int64
	CreatedAt          time.Time
	UpdatedAt          time.Time
	DeletedAt          *time.Time
}

func (n Node) IsDeleted() bool { return n.DeletedAt != nil }

type Service struct {
	db  *sql.DB
	now func() time.Time
}

func New(db *sql.DB) *Service { return &Service{db: db, now: time.Now} }

type CreateInput struct {
	ID, OwnerID, DeviceID, OperationID string
	ParentID                           *string
	NodeType                           string
	MetadataCiphertext                 []byte
	MetadataKeyVersion                 int
}

// Create inserts an opaque node. For NodeType FILE this only creates the
// placeholder the client will attach a FileVersion to via the uploads
// service (internal/uploads); CurrentVersionID stays nil until then.
func (s *Service) Create(ctx context.Context, in CreateInput) (Node, error) {
	if !validUUID(in.ID) || !validUUID(in.OperationID) {
		return Node{}, apierror.NewValidation("node id and operation id must be valid UUIDs")
	}
	if in.NodeType != "FILE" && in.NodeType != "DIRECTORY" {
		return Node{}, apierror.NewValidation("node type must be FILE or DIRECTORY")
	}
	if len(in.MetadataCiphertext) == 0 || in.MetadataKeyVersion < 1 {
		return Node{}, apierror.NewValidation("encrypted metadata and a key version are required")
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Node{}, err
	}
	defer tx.Rollback()

	if result, err := s.replayIfProcessed(ctx, tx, in.OperationID); err != nil {
		return Node{}, err
	} else if result != nil {
		// Release the connection before Get acquires one of its own — this
		// service runs against a single-connection SQLite pool, so calling
		// Get while tx is still open (its deferred Rollback hasn't run yet)
		// would deadlock waiting for a connection tx itself is holding.
		tx.Rollback()
		return s.Get(ctx, in.OwnerID, result.nodeID)
	}
	if err := s.validateDeviceOwnership(ctx, tx, in.OwnerID, in.DeviceID); err != nil {
		return Node{}, err
	}
	if in.ParentID != nil {
		if err := s.requireDirectory(ctx, tx, in.OwnerID, *in.ParentID); err != nil {
			return Node{}, err
		}
	}

	now := s.now().UTC()
	revision, err := s.recordChange(ctx, tx, in.OwnerID, in.ID, "CREATE")
	if err != nil {
		return Node{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO nodes
		(id,owner_id,parent_id,node_type,metadata_ciphertext,metadata_key_version,revision,created_at,updated_at)
		VALUES (?,?,?,?,?,?,?,?,?)`,
		in.ID, in.OwnerID, nullableString(in.ParentID), in.NodeType, in.MetadataCiphertext, in.MetadataKeyVersion,
		revision, now.Format(time.RFC3339Nano), now.Format(time.RFC3339Nano)); err != nil {
		return Node{}, fmt.Errorf("create node: %w", err)
	}
	if err := s.recordProcessed(ctx, tx, in.OperationID, in.OwnerID, in.DeviceID, "NODE_CREATE", in.ID, revision); err != nil {
		return Node{}, err
	}
	if err := tx.Commit(); err != nil {
		return Node{}, err
	}
	return s.Get(ctx, in.OwnerID, in.ID)
}

func (s *Service) Get(ctx context.Context, userID, nodeID string) (Node, error) {
	row := s.db.QueryRowContext(ctx, selectNodeColumns+" FROM nodes WHERE id = ?", nodeID)
	n, err := scanNode(row)
	if errors.Is(err, sql.ErrNoRows) {
		return Node{}, ErrNotFound
	}
	if err != nil {
		return Node{}, err
	}
	if n.OwnerID != userID && (n.IsDeleted() || !s.hasReadShare(ctx, userID, nodeID)) {
		return Node{}, ErrForbidden
	}
	return n, nil
}

// ListChildren returns the non-deleted direct children of parentID, or the
// caller's root-level nodes when parentID is nil.
func (s *Service) ListChildren(ctx context.Context, userID string, parentID *string) ([]Node, error) {
	var rows *sql.Rows
	var err error
	if parentID == nil {
		rows, err = s.db.QueryContext(ctx, `SELECT n.id,n.owner_id,n.parent_id,n.node_type,n.metadata_ciphertext,n.metadata_key_version,n.current_version_id,n.revision,n.created_at,n.updated_at,n.deleted_at
			FROM nodes n WHERE n.owner_id=? AND n.parent_id IS NULL AND n.deleted_at IS NULL
			UNION ALL
			SELECT n.id,n.owner_id,n.parent_id,n.node_type,n.metadata_ciphertext,n.metadata_key_version,n.current_version_id,n.revision,n.created_at,n.updated_at,n.deleted_at
			FROM nodes n JOIN shares sh ON sh.node_id=n.id
			WHERE sh.target_user_id=? AND sh.permission='READ' AND sh.revoked_at IS NULL AND n.deleted_at IS NULL
			ORDER BY created_at`, userID, userID)
	} else {
		if err := s.requireReadableDirectory(ctx, userID, *parentID); err != nil {
			return nil, err
		}
		rows, err = s.db.QueryContext(ctx, selectNodeColumns+" FROM nodes WHERE parent_id = ? AND deleted_at IS NULL ORDER BY created_at", *parentID)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var nodes []Node
	for rows.Next() {
		n, err := scanNode(rows)
		if err != nil {
			return nil, err
		}
		nodes = append(nodes, n)
	}
	return nodes, rows.Err()
}

// ListOwnedRoots returns only the caller's active root nodes. Unlike
// ListChildren(nil), it deliberately excludes read-only roots shared by
// another account, which is required by owner-only bulk workflows such as a
// client-side Vault rebuild.
func (s *Service) ListOwnedRoots(ctx context.Context, userID string) ([]Node, error) {
	rows, err := s.db.QueryContext(ctx, selectNodeColumns+" FROM nodes WHERE owner_id = ? AND parent_id IS NULL AND deleted_at IS NULL ORDER BY created_at", userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []Node
	for rows.Next() {
		n, err := scanNode(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, n)
	}
	return result, rows.Err()
}

func (s *Service) requireReadableDirectory(ctx context.Context, userID, nodeID string) error {
	var nodeType string
	var deleted sql.NullString
	var ownerID string
	err := s.db.QueryRowContext(ctx, "SELECT owner_id,node_type,deleted_at FROM nodes WHERE id=?", nodeID).Scan(&ownerID, &nodeType, &deleted)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrInvalidParent
	}
	if err != nil {
		return err
	}
	if nodeType != "DIRECTORY" || deleted.Valid || (ownerID != userID && !s.hasReadShare(ctx, userID, nodeID)) {
		return ErrForbidden
	}
	return nil
}

// hasReadShare authorizes any descendant of a shared folder, not just the
// root itself. The recursive walk is bounded by SQLite's recursion limit and
// the existing node mutation cycle checks.
func (s *Service) hasReadShare(ctx context.Context, userID, nodeID string) bool {
	var allowed bool
	err := s.db.QueryRowContext(ctx, `WITH RECURSIVE ancestors(id,parent_id) AS (
		SELECT id,parent_id FROM nodes WHERE id=?
		UNION ALL SELECT n.id,n.parent_id FROM nodes n JOIN ancestors a ON a.parent_id=n.id
	) SELECT EXISTS(SELECT 1 FROM shares sh JOIN ancestors a ON a.id=sh.node_id
		WHERE sh.target_user_id=? AND sh.permission='READ' AND sh.revoked_at IS NULL)`, nodeID, userID).Scan(&allowed)
	return err == nil && allowed
}

type UpdateInput struct {
	UserID, DeviceID, OperationID, NodeID string
	ExpectedRevision                      int64
	MetadataCiphertext                    []byte // nil = leave unchanged
	MetadataKeyVersion                    int
	MoveParent                            bool // when true, ParentID (possibly nil, meaning root) replaces the current parent
	ParentID                              *string
}

// Update renames/moves a node and/or replaces its encrypted metadata in one
// optimistic-concurrency-checked mutation (spec §17.3's single PATCH
// endpoint). At least one of a metadata change or a move must be requested.
func (s *Service) Update(ctx context.Context, in UpdateInput) (Node, error) {
	if !validUUID(in.NodeID) || !validUUID(in.OperationID) {
		return Node{}, apierror.NewValidation("node id and operation id must be valid UUIDs")
	}
	if len(in.MetadataCiphertext) == 0 && !in.MoveParent {
		return Node{}, apierror.NewValidation("update must change metadata, parent, or both")
	}
	if len(in.MetadataCiphertext) > 0 && in.MetadataKeyVersion < 1 {
		return Node{}, apierror.NewValidation("a metadata key version is required when metadata changes")
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Node{}, err
	}
	defer tx.Rollback()

	if result, err := s.replayIfProcessed(ctx, tx, in.OperationID); err != nil {
		return Node{}, err
	} else if result != nil {
		tx.Rollback() // see the identical comment in Create.
		return s.Get(ctx, in.UserID, result.nodeID)
	}
	if err := s.validateDeviceOwnership(ctx, tx, in.UserID, in.DeviceID); err != nil {
		return Node{}, err
	}

	current, err := s.lockNode(ctx, tx, in.UserID, in.NodeID)
	if err != nil {
		return Node{}, err
	}
	if current.Revision != in.ExpectedRevision {
		return Node{}, ErrRevisionConflict
	}
	if in.MoveParent {
		if in.ParentID != nil {
			if *in.ParentID == in.NodeID {
				return Node{}, apierror.NewValidation("a node cannot become its own parent")
			}
			if err := s.requireDirectory(ctx, tx, in.UserID, *in.ParentID); err != nil {
				return Node{}, err
			}
			if err := s.forbidCycle(ctx, tx, in.NodeID, *in.ParentID); err != nil {
				return Node{}, err
			}
		}
	}

	now := s.now().UTC()
	revision, err := s.recordChange(ctx, tx, in.UserID, in.NodeID, "UPDATE")
	if err != nil {
		return Node{}, err
	}
	switch {
	case len(in.MetadataCiphertext) > 0 && in.MoveParent:
		_, err = tx.ExecContext(ctx, `UPDATE nodes SET metadata_ciphertext=?, metadata_key_version=?, parent_id=?, revision=?, updated_at=? WHERE id=?`,
			in.MetadataCiphertext, in.MetadataKeyVersion, nullableString(in.ParentID), revision, now.Format(time.RFC3339Nano), in.NodeID)
	case len(in.MetadataCiphertext) > 0:
		_, err = tx.ExecContext(ctx, `UPDATE nodes SET metadata_ciphertext=?, metadata_key_version=?, revision=?, updated_at=? WHERE id=?`,
			in.MetadataCiphertext, in.MetadataKeyVersion, revision, now.Format(time.RFC3339Nano), in.NodeID)
	default:
		_, err = tx.ExecContext(ctx, `UPDATE nodes SET parent_id=?, revision=?, updated_at=? WHERE id=?`,
			nullableString(in.ParentID), revision, now.Format(time.RFC3339Nano), in.NodeID)
	}
	if err != nil {
		return Node{}, fmt.Errorf("update node: %w", err)
	}
	if err := s.recordProcessed(ctx, tx, in.OperationID, in.UserID, in.DeviceID, "NODE_UPDATE", in.NodeID, revision); err != nil {
		return Node{}, err
	}
	if err := tx.Commit(); err != nil {
		return Node{}, err
	}
	return s.Get(ctx, in.UserID, in.NodeID)
}

// Delete soft-deletes a node (moves it to Trash, spec §27.2). It does not
// touch descendants' rows; they remain reachable by ID but are excluded
// from ListChildren once their ancestor is deleted, matching how a
// filesystem trash typically behaves. Restoring only the top node again
// exposes its subtree.
func (s *Service) Delete(ctx context.Context, userID, deviceID, nodeID, operationID string, expectedRevision int64) error {
	if !validUUID(nodeID) || !validUUID(operationID) {
		return apierror.NewValidation("node id and operation id must be valid UUIDs")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if result, err := s.replayIfProcessed(ctx, tx, operationID); err != nil {
		return err
	} else if result != nil {
		return nil
	}
	if err := s.validateDeviceOwnership(ctx, tx, userID, deviceID); err != nil {
		return err
	}
	current, err := s.lockNode(ctx, tx, userID, nodeID)
	if err != nil {
		return err
	}
	if current.Revision != expectedRevision {
		return ErrRevisionConflict
	}

	now := s.now().UTC()
	revision, err := s.recordChange(ctx, tx, userID, nodeID, "DELETE")
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE nodes SET deleted_at=?, revision=?, updated_at=? WHERE id=?`,
		now.Format(time.RFC3339Nano), revision, now.Format(time.RFC3339Nano), nodeID); err != nil {
		return fmt.Errorf("delete node: %w", err)
	}
	if err := s.recordProcessed(ctx, tx, operationID, userID, deviceID, "NODE_DELETE", nodeID, revision); err != nil {
		return err
	}
	return tx.Commit()
}

// Restore reverses a soft delete without rewriting history: it is a new
// mutation with a new revision, not a rollback (spec §27.1's "restore
// creates a new current version" principle applied to node lifecycle).
func (s *Service) Restore(ctx context.Context, userID, deviceID, nodeID, operationID string) (Node, error) {
	if !validUUID(nodeID) || !validUUID(operationID) {
		return Node{}, apierror.NewValidation("node id and operation id must be valid UUIDs")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Node{}, err
	}
	defer tx.Rollback()

	if result, err := s.replayIfProcessed(ctx, tx, operationID); err != nil {
		return Node{}, err
	} else if result != nil {
		tx.Rollback() // see the identical comment in Create.
		return s.Get(ctx, userID, result.nodeID)
	}
	if err := s.validateDeviceOwnership(ctx, tx, userID, deviceID); err != nil {
		return Node{}, err
	}
	var ownerID string
	var deletedAt sql.NullString
	if err := tx.QueryRowContext(ctx, "SELECT owner_id, deleted_at FROM nodes WHERE id = ?", nodeID).Scan(&ownerID, &deletedAt); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Node{}, ErrNotFound
		}
		return Node{}, err
	}
	if ownerID != userID {
		return Node{}, ErrForbidden
	}
	if !deletedAt.Valid {
		return Node{}, apierror.NewValidation("node is not in trash")
	}

	now := s.now().UTC()
	revision, err := s.recordChange(ctx, tx, userID, nodeID, "RESTORE")
	if err != nil {
		return Node{}, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE nodes SET deleted_at=NULL, revision=?, updated_at=? WHERE id=?`,
		revision, now.Format(time.RFC3339Nano), nodeID); err != nil {
		return Node{}, fmt.Errorf("restore node: %w", err)
	}
	if err := s.recordProcessed(ctx, tx, operationID, userID, deviceID, "NODE_RESTORE", nodeID, revision); err != nil {
		return Node{}, err
	}
	if err := tx.Commit(); err != nil {
		return Node{}, err
	}
	return s.Get(ctx, userID, nodeID)
}

// ListTrash returns the caller's soft-deleted nodes (spec §17.7).
func (s *Service) ListTrash(ctx context.Context, userID string) ([]Node, error) {
	rows, err := s.db.QueryContext(ctx, selectNodeColumns+" FROM nodes WHERE owner_id = ? AND deleted_at IS NOT NULL ORDER BY deleted_at DESC", userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var nodes []Node
	for rows.Next() {
		n, err := scanNode(rows)
		if err != nil {
			return nil, err
		}
		nodes = append(nodes, n)
	}
	return nodes, rows.Err()
}

const selectNodeColumns = `SELECT id,owner_id,parent_id,node_type,metadata_ciphertext,metadata_key_version,current_version_id,revision,created_at,updated_at,deleted_at`

type rowScanner interface {
	Scan(dest ...any) error
}

func scanNode(row rowScanner) (Node, error) {
	var n Node
	var parentID, currentVersionID, deletedAt sql.NullString
	var createdAt, updatedAt string
	if err := row.Scan(&n.ID, &n.OwnerID, &parentID, &n.NodeType, &n.MetadataCiphertext, &n.MetadataKeyVersion,
		&currentVersionID, &n.Revision, &createdAt, &updatedAt, &deletedAt); err != nil {
		return Node{}, err
	}
	if parentID.Valid {
		n.ParentID = &parentID.String
	}
	if currentVersionID.Valid {
		n.CurrentVersionID = &currentVersionID.String
	}
	var err error
	if n.CreatedAt, err = time.Parse(time.RFC3339Nano, createdAt); err != nil {
		return Node{}, err
	}
	if n.UpdatedAt, err = time.Parse(time.RFC3339Nano, updatedAt); err != nil {
		return Node{}, err
	}
	if deletedAt.Valid {
		t, err := time.Parse(time.RFC3339Nano, deletedAt.String)
		if err != nil {
			return Node{}, err
		}
		n.DeletedAt = &t
	}
	return n, nil
}

func (s *Service) lockNode(ctx context.Context, tx *sql.Tx, userID, nodeID string) (Node, error) {
	row := tx.QueryRowContext(ctx, selectNodeColumns+" FROM nodes WHERE id = ?", nodeID)
	n, err := scanNode(row)
	if errors.Is(err, sql.ErrNoRows) {
		return Node{}, ErrNotFound
	}
	if err != nil {
		return Node{}, err
	}
	if n.OwnerID != userID {
		return Node{}, ErrForbidden
	}
	if n.IsDeleted() {
		return Node{}, apierror.NewValidation("node is in trash; restore it before updating")
	}
	return n, nil
}

func (s *Service) requireDirectory(ctx context.Context, tx queryRower, userID, nodeID string) error {
	var ownerID, nodeType string
	var deletedAt sql.NullString
	q := s.db.QueryRowContext
	if tx != nil {
		q = tx.QueryRowContext
	}
	err := q(ctx, "SELECT owner_id, node_type, deleted_at FROM nodes WHERE id = ?", nodeID).Scan(&ownerID, &nodeType, &deletedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrInvalidParent
	}
	if err != nil {
		return err
	}
	if ownerID != userID || nodeType != "DIRECTORY" || deletedAt.Valid {
		return ErrInvalidParent
	}
	return nil
}

// forbidCycle walks newParentID's ancestor chain to ensure movingNodeID is
// not among them, which would otherwise detach a subtree from the tree
// entirely (a node cannot become a descendant of itself).
func (s *Service) forbidCycle(ctx context.Context, tx *sql.Tx, movingNodeID, newParentID string) error {
	current := newParentID
	for i := 0; i < 10_000; i++ {
		if current == movingNodeID {
			return apierror.NewValidation("move would create a cycle")
		}
		var parent sql.NullString
		if err := tx.QueryRowContext(ctx, "SELECT parent_id FROM nodes WHERE id = ?", current).Scan(&parent); err != nil {
			return err
		}
		if !parent.Valid {
			return nil
		}
		current = parent.String
	}
	return apierror.NewValidation("directory tree exceeds maximum supported depth")
}

func (s *Service) validateDeviceOwnership(ctx context.Context, tx *sql.Tx, userID, deviceID string) error {
	var count int
	if err := tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM devices WHERE id=? AND user_id=? AND revoked_at IS NULL", deviceID, userID).Scan(&count); err != nil {
		return err
	}
	if count != 1 {
		return ErrForbidden
	}
	return nil
}

// recordChange inserts the sync_changes row that backs the global revision
// counter (ADR-005) and returns the new revision, which the caller then
// stamps onto the affected node in the same transaction.
func (s *Service) recordChange(ctx context.Context, tx *sql.Tx, userID, nodeID, operation string) (int64, error) {
	now := s.now().UTC().Format(time.RFC3339Nano)
	if _, err := tx.ExecContext(ctx, `INSERT INTO sync_changes (user_scope_id,node_id,operation,created_at) VALUES (?,?,?,?)`,
		userID, nodeID, operation, now); err != nil {
		return 0, err
	}
	var revision int64
	if err := tx.QueryRowContext(ctx, "SELECT last_insert_rowid()").Scan(&revision); err != nil {
		return 0, err
	}
	return revision, nil
}

type processedResult struct {
	nodeID   string
	revision int64
}

func (s *Service) replayIfProcessed(ctx context.Context, tx *sql.Tx, operationID string) (*processedResult, error) {
	var payload []byte
	err := tx.QueryRowContext(ctx, "SELECT result_payload FROM processed_operations WHERE operation_id=?", operationID).Scan(&payload)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	fields := strings.SplitN(string(payload), ":", 2)
	if len(fields) != 2 || !validUUID(fields[0]) {
		return nil, errors.New("invalid stored operation result")
	}
	revision, err := strconv.ParseInt(fields[1], 10, 64)
	if err != nil {
		return nil, err
	}
	return &processedResult{nodeID: fields[0], revision: revision}, nil
}

func (s *Service) recordProcessed(ctx context.Context, tx *sql.Tx, operationID, userID, deviceID, operationType, nodeID string, revision int64) error {
	now := s.now().UTC()
	payload := []byte(nodeID + ":" + strconv.FormatInt(revision, 10))
	_, err := tx.ExecContext(ctx, `INSERT INTO processed_operations (operation_id,user_id,device_id,operation_type,result_code,result_payload,created_at,expires_at)
		VALUES (?,?,?,?,'OK',?,?,?)`, operationID, userID, deviceID, operationType, payload, now.Format(time.RFC3339Nano), now.Add(30*24*time.Hour).Format(time.RFC3339Nano))
	return err
}

type queryRower interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

func validUUID(v string) bool { _, err := uuid.Parse(v); return err == nil }
func nullableString(v *string) any {
	if v == nil {
		return nil
	}
	return *v
}
