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
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/homebox/homebox/internal/access"
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
	// MetadataKeyScopeID names the key that encrypts MetadataCiphertext:
	// OwnerID for the owner's personal Vault Key, or the ID of the shared
	// folder whose Folder Key encrypts this subtree (ADR-023).
	MetadataKeyScopeID string
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

// CreateInput describes a new node. OwnerID is the requesting account: the
// node is normally stored under it, but inside a folder shared with that
// account for READ_WRITE it is stored under the folder owner's account
// instead, so the owner keeps a single tree, Trash, and sync feed.
type CreateInput struct {
	ID, OwnerID, DeviceID, OperationID string
	ParentID                           *string
	NodeType                           string
	MetadataCiphertext                 []byte
	MetadataKeyVersion                 int
	// MetadataKeyScopeID is the declared metadata key scope; empty means
	// the owner's personal Vault Key.
	MetadataKeyScopeID string
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

	if result, err := s.replayIfProcessed(ctx, tx, in.OperationID, in.OwnerID, "NODE_CREATE"); err != nil {
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
	ownerID := in.OwnerID
	writeRoot := ""
	if in.ParentID != nil {
		parentOwner, err := s.directoryOwner(ctx, tx, *in.ParentID)
		if err != nil {
			return Node{}, err
		}
		if parentOwner != in.OwnerID {
			grant, found, err := access.ShareGrant(ctx, tx, in.OwnerID, *in.ParentID)
			if err != nil {
				return Node{}, err
			}
			if !found || !grant.CanWrite() {
				return Node{}, ErrInvalidParent
			}
			ownerID, writeRoot = parentOwner, grant.RootID
		}
	}
	scope := in.MetadataKeyScopeID
	if scope == "" {
		scope = ownerID
	}
	if err := access.ValidateKeyScope(ctx, tx, ownerID, in.OwnerID, writeRoot, scope, in.MetadataKeyVersion); err != nil {
		return Node{}, err
	}

	now := s.now().UTC()
	revision, err := s.recordChange(ctx, tx, ownerID, in.ID, "CREATE")
	if err != nil {
		return Node{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO nodes
		(id,owner_id,parent_id,node_type,metadata_ciphertext,metadata_key_version,metadata_key_scope_id,revision,created_at,updated_at)
		VALUES (?,?,?,?,?,?,?,?,?,?)`,
		in.ID, ownerID, nullableString(in.ParentID), in.NodeType, in.MetadataCiphertext, in.MetadataKeyVersion,
		access.StoredScope(scope, ownerID), revision, now.Format(time.RFC3339Nano), now.Format(time.RFC3339Nano)); err != nil {
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
	if n.OwnerID != userID {
		if n.IsDeleted() {
			return Node{}, ErrForbidden
		}
		if _, shared, err := access.ShareGrant(ctx, s.db, userID, nodeID); err != nil {
			return Node{}, err
		} else if !shared {
			return Node{}, ErrForbidden
		}
	}
	return n, nil
}

// ListChildren returns the non-deleted direct children of parentID, or the
// caller's root-level nodes when parentID is nil.
func (s *Service) ListChildren(ctx context.Context, userID string, parentID *string) ([]Node, error) {
	nodes, _, err := s.ListChildrenPage(ctx, userID, parentID, PageRequest{})
	return nodes, err
}

// ListOwnedRoots returns only the caller's active root nodes. Unlike
// ListChildren(nil), it deliberately excludes read-only roots shared by
// another account, which is required by owner-only bulk workflows such as a
// client-side Vault rebuild.
func (s *Service) ListOwnedRoots(ctx context.Context, userID string) ([]Node, error) {
	nodes, _, err := s.ListOwnedRootsPage(ctx, userID, PageRequest{})
	return nodes, err
}

// MaxPageSize caps one page of a directory listing.
const MaxPageSize = 1000

// PageRequest selects one keyset page of a listing ordered by
// (created_at, id). A zero Limit returns every remaining row; After is the
// opaque cursor returned with the previous page.
type PageRequest struct {
	Limit int
	After string
}

// ListChildrenPage is ListChildren with keyset pagination. The returned
// cursor is empty once the listing is exhausted.
func (s *Service) ListChildrenPage(ctx context.Context, userID string, parentID *string, page PageRequest) ([]Node, string, error) {
	if parentID == nil {
		return s.listPage(ctx, `SELECT `+nodeColumnsN+`
			FROM nodes n WHERE n.owner_id=? AND n.parent_id IS NULL AND n.deleted_at IS NULL
			UNION ALL
			SELECT `+nodeColumnsN+`
			FROM nodes n JOIN shares sh ON sh.node_id=n.id
			WHERE sh.target_user_id=? AND sh.revoked_at IS NULL AND n.deleted_at IS NULL`, page, userID, userID)
	}
	if err := s.requireReadableDirectory(ctx, userID, *parentID); err != nil {
		return nil, "", err
	}
	return s.listPage(ctx, selectNodeColumns+" FROM nodes WHERE parent_id = ? AND deleted_at IS NULL", page, *parentID)
}

// ListOwnedRootsPage is ListOwnedRoots with keyset pagination.
func (s *Service) ListOwnedRootsPage(ctx context.Context, userID string, page PageRequest) ([]Node, string, error) {
	return s.listPage(ctx, selectNodeColumns+" FROM nodes WHERE owner_id = ? AND parent_id IS NULL AND deleted_at IS NULL", page, userID)
}

func (s *Service) listPage(ctx context.Context, base string, page PageRequest, args ...any) ([]Node, string, error) {
	if page.Limit < 0 || page.Limit > MaxPageSize {
		return nil, "", apierror.NewValidation(fmt.Sprintf("page limit must be between 1 and %d", MaxPageSize))
	}
	query := "SELECT * FROM (" + base + ") page"
	if page.After != "" {
		createdAt, id, err := decodeCursor(page.After)
		if err != nil {
			return nil, "", err
		}
		query += " WHERE (page.created_at, page.id) > (?, ?)"
		args = append(args, createdAt, id)
	}
	query += " ORDER BY page.created_at, page.id"
	if page.Limit > 0 {
		// One extra row tells whether another page exists.
		query += " LIMIT ?"
		args = append(args, page.Limit+1)
	}
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, "", err
	}
	defer rows.Close()
	var nodes []Node
	var createdAt []string
	for rows.Next() {
		n, raw, err := scanNodeWithCreatedAt(rows)
		if err != nil {
			return nil, "", err
		}
		nodes = append(nodes, n)
		createdAt = append(createdAt, raw)
	}
	if err := rows.Err(); err != nil {
		return nil, "", err
	}
	if page.Limit == 0 || len(nodes) <= page.Limit {
		return nodes, "", nil
	}
	nodes = nodes[:page.Limit]
	last := page.Limit - 1
	return nodes, encodeCursor(createdAt[last], nodes[last].ID), nil
}

// The cursor carries the stored created_at text verbatim so the keyset
// comparison matches ORDER BY exactly.
func encodeCursor(createdAt, id string) string {
	return base64.RawURLEncoding.EncodeToString([]byte(createdAt + "|" + id))
}

func decodeCursor(cursor string) (string, string, error) {
	raw, err := base64.RawURLEncoding.DecodeString(cursor)
	if err != nil {
		return "", "", apierror.NewValidation("invalid page cursor")
	}
	createdAt, id, ok := strings.Cut(string(raw), "|")
	if !ok || uuid.Validate(id) != nil {
		return "", "", apierror.NewValidation("invalid page cursor")
	}
	if _, err := time.Parse(time.RFC3339Nano, createdAt); err != nil {
		return "", "", apierror.NewValidation("invalid page cursor")
	}
	return createdAt, id, nil
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
	if nodeType != "DIRECTORY" || deleted.Valid {
		return ErrForbidden
	}
	if ownerID != userID {
		// Any active grant, READ or READ_WRITE, lets a recipient browse.
		if _, shared, err := access.ShareGrant(ctx, s.db, userID, nodeID); err != nil {
			return err
		} else if !shared {
			return ErrForbidden
		}
	}
	return nil
}

type UpdateInput struct {
	UserID, DeviceID, OperationID, NodeID string
	ExpectedRevision                      int64
	MetadataCiphertext                    []byte // nil = leave unchanged
	MetadataKeyVersion                    int
	// MetadataKeyScopeID is the declared scope of new metadata; empty means
	// the owner's personal Vault Key.
	MetadataKeyScopeID string
	MoveParent         bool // when true, ParentID (possibly nil, meaning root) replaces the current parent
	ParentID           *string
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

	if result, err := s.replayIfProcessed(ctx, tx, in.OperationID, in.UserID, "NODE_UPDATE"); err != nil {
		return Node{}, err
	} else if result != nil {
		tx.Rollback() // see the identical comment in Create.
		return s.Get(ctx, in.UserID, result.nodeID)
	}
	if err := s.validateDeviceOwnership(ctx, tx, in.UserID, in.DeviceID); err != nil {
		return Node{}, err
	}

	current, err := s.lockNode(ctx, tx, in.NodeID)
	if err != nil {
		return Node{}, err
	}
	writeRoot, err := s.authorizeWrite(ctx, tx, in.UserID, current)
	if err != nil {
		return Node{}, err
	}
	if current.Revision != in.ExpectedRevision {
		return Node{}, ErrRevisionConflict
	}
	if in.MoveParent {
		if err := s.validateMove(ctx, tx, in.UserID, current, writeRoot, in.ParentID); err != nil {
			return Node{}, err
		}
	}
	scope := in.MetadataKeyScopeID
	if scope == "" {
		scope = current.OwnerID
	}
	if len(in.MetadataCiphertext) > 0 {
		if err := access.ValidateKeyScope(ctx, tx, current.OwnerID, in.UserID, writeRoot, scope, in.MetadataKeyVersion); err != nil {
			return Node{}, err
		}
	}

	now := s.now().UTC()
	revision, err := s.recordChange(ctx, tx, current.OwnerID, in.NodeID, "UPDATE")
	if err != nil {
		return Node{}, err
	}
	switch {
	case len(in.MetadataCiphertext) > 0 && in.MoveParent:
		_, err = tx.ExecContext(ctx, `UPDATE nodes SET metadata_ciphertext=?, metadata_key_version=?, metadata_key_scope_id=?, parent_id=?, revision=?, updated_at=? WHERE id=?`,
			in.MetadataCiphertext, in.MetadataKeyVersion, access.StoredScope(scope, current.OwnerID), nullableString(in.ParentID), revision, now.Format(time.RFC3339Nano), in.NodeID)
	case len(in.MetadataCiphertext) > 0:
		_, err = tx.ExecContext(ctx, `UPDATE nodes SET metadata_ciphertext=?, metadata_key_version=?, metadata_key_scope_id=?, revision=?, updated_at=? WHERE id=?`,
			in.MetadataCiphertext, in.MetadataKeyVersion, access.StoredScope(scope, current.OwnerID), revision, now.Format(time.RFC3339Nano), in.NodeID)
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

	if result, err := s.replayIfProcessed(ctx, tx, operationID, userID, "NODE_DELETE"); err != nil {
		return err
	} else if result != nil {
		return nil
	}
	if err := s.validateDeviceOwnership(ctx, tx, userID, deviceID); err != nil {
		return err
	}
	current, err := s.lockNode(ctx, tx, nodeID)
	if err != nil {
		return err
	}
	if _, err := s.authorizeWrite(ctx, tx, userID, current); err != nil {
		return err
	}
	if current.Revision != expectedRevision {
		return ErrRevisionConflict
	}

	now := s.now().UTC()
	revision, err := s.recordChange(ctx, tx, current.OwnerID, nodeID, "DELETE")
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

	if result, err := s.replayIfProcessed(ctx, tx, operationID, userID, "NODE_RESTORE"); err != nil {
		return Node{}, err
	} else if result != nil {
		tx.Rollback() // see the identical comment in Create.
		return s.Get(ctx, userID, result.nodeID)
	}
	if err := s.validateDeviceOwnership(ctx, tx, userID, deviceID); err != nil {
		return Node{}, err
	}
	var ownerID string
	var parentID, deletedAt sql.NullString
	if err := tx.QueryRowContext(ctx, "SELECT owner_id, parent_id, deleted_at FROM nodes WHERE id = ?", nodeID).Scan(&ownerID, &parentID, &deletedAt); err != nil {
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
	// A node restored under a folder that is itself still in Trash would stay
	// invisible, and the folder's retention purge would later delete it for
	// good together with the rest of that subtree. Restore it to the root
	// instead, where the owner can see it and move it on.
	toRoot := false
	if parentID.Valid {
		if toRoot, err = s.hasDeletedAncestor(ctx, tx, parentID.String); err != nil {
			return Node{}, err
		}
	}

	now := s.now().UTC()
	revision, err := s.recordChange(ctx, tx, userID, nodeID, "RESTORE")
	if err != nil {
		return Node{}, err
	}
	restoreSQL := `UPDATE nodes SET deleted_at=NULL, revision=?, updated_at=? WHERE id=?`
	if toRoot {
		restoreSQL = `UPDATE nodes SET deleted_at=NULL, parent_id=NULL, revision=?, updated_at=? WHERE id=?`
	}
	if _, err := tx.ExecContext(ctx, restoreSQL, revision, now.Format(time.RFC3339Nano), nodeID); err != nil {
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

// hasDeletedAncestor reports whether nodeID or any folder above it is in
// Trash (or no longer exists), i.e. whether a child placed there is hidden.
func (s *Service) hasDeletedAncestor(ctx context.Context, tx *sql.Tx, nodeID string) (bool, error) {
	var hidden bool
	err := tx.QueryRowContext(ctx, `WITH RECURSIVE ancestors(id,parent_id,deleted_at) AS (
		SELECT id,parent_id,deleted_at FROM nodes WHERE id=?
		UNION SELECT n.id,n.parent_id,n.deleted_at FROM nodes n JOIN ancestors a ON a.parent_id=n.id
	) SELECT NOT EXISTS(SELECT 1 FROM ancestors WHERE id=?) OR EXISTS(SELECT 1 FROM ancestors WHERE deleted_at IS NOT NULL)`,
		nodeID, nodeID).Scan(&hidden)
	return hidden, err
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

const selectNodeColumns = `SELECT id,owner_id,parent_id,node_type,metadata_ciphertext,metadata_key_version,current_version_id,revision,created_at,updated_at,deleted_at,COALESCE(metadata_key_scope_id,owner_id) AS metadata_key_scope_id`

// nodeColumnsN is selectNodeColumns for queries that alias nodes as n.
const nodeColumnsN = `n.id,n.owner_id,n.parent_id,n.node_type,n.metadata_ciphertext,n.metadata_key_version,n.current_version_id,n.revision,n.created_at,n.updated_at,n.deleted_at,COALESCE(n.metadata_key_scope_id,n.owner_id) AS metadata_key_scope_id`

type rowScanner interface {
	Scan(dest ...any) error
}

func scanNode(row rowScanner) (Node, error) {
	n, _, err := scanNodeWithCreatedAt(row)
	return n, err
}

// scanNodeWithCreatedAt also returns the raw stored created_at text, which
// keyset pagination cursors must reproduce byte for byte.
func scanNodeWithCreatedAt(row rowScanner) (Node, string, error) {
	var n Node
	var parentID, currentVersionID, deletedAt sql.NullString
	var createdAt, updatedAt string
	if err := row.Scan(&n.ID, &n.OwnerID, &parentID, &n.NodeType, &n.MetadataCiphertext, &n.MetadataKeyVersion,
		&currentVersionID, &n.Revision, &createdAt, &updatedAt, &deletedAt, &n.MetadataKeyScopeID); err != nil {
		return Node{}, "", err
	}
	if parentID.Valid {
		n.ParentID = &parentID.String
	}
	if currentVersionID.Valid {
		n.CurrentVersionID = &currentVersionID.String
	}
	var err error
	if n.CreatedAt, err = time.Parse(time.RFC3339Nano, createdAt); err != nil {
		return Node{}, "", err
	}
	if n.UpdatedAt, err = time.Parse(time.RFC3339Nano, updatedAt); err != nil {
		return Node{}, "", err
	}
	if deletedAt.Valid {
		t, err := time.Parse(time.RFC3339Nano, deletedAt.String)
		if err != nil {
			return Node{}, "", err
		}
		n.DeletedAt = &t
	}
	return n, createdAt, nil
}

// lockNode reads a node that is about to be mutated. Callers authorize the
// actor with authorizeWrite before relying on it.
func (s *Service) lockNode(ctx context.Context, tx *sql.Tx, nodeID string) (Node, error) {
	row := tx.QueryRowContext(ctx, selectNodeColumns+" FROM nodes WHERE id = ?", nodeID)
	n, err := scanNode(row)
	if errors.Is(err, sql.ErrNoRows) {
		return Node{}, ErrNotFound
	}
	if err != nil {
		return Node{}, err
	}
	return n, nil
}

// authorizeWrite lets the owner change any of its nodes, and a READ_WRITE
// recipient change nodes strictly below the shared root. The root itself
// stays under the owner's control: a member can neither rename, move, nor
// delete the folder that was shared with them. writeRoot is that share
// root for a recipient and "" for the owner.
func (s *Service) authorizeWrite(ctx context.Context, tx *sql.Tx, userID string, n Node) (writeRoot string, err error) {
	if n.OwnerID != userID {
		grant, found, err := access.ShareGrant(ctx, tx, userID, n.ID)
		if err != nil {
			return "", err
		}
		if !found || !grant.CanWrite() || grant.RootID == n.ID {
			return "", ErrForbidden
		}
		writeRoot = grant.RootID
	}
	if n.IsDeleted() {
		return "", apierror.NewValidation("node is in trash; restore it before updating")
	}
	return writeRoot, nil
}

// validateMove checks a new parent. A recipient may move a node only within
// the folder shared with it; the owner may move anywhere in its own tree as
// long as shared folders never end up nested.
func (s *Service) validateMove(ctx context.Context, tx *sql.Tx, userID string, n Node, writeRoot string, parentID *string) error {
	if parentID == nil {
		if writeRoot != "" {
			return ErrInvalidParent
		}
		return nil
	}
	if *parentID == n.ID {
		return apierror.NewValidation("a node cannot become its own parent")
	}
	parentOwner, err := s.directoryOwner(ctx, tx, *parentID)
	if err != nil {
		return err
	}
	if parentOwner != n.OwnerID {
		return ErrInvalidParent
	}
	if writeRoot != "" {
		grant, found, err := access.ShareGrant(ctx, tx, userID, *parentID)
		if err != nil {
			return err
		}
		if !found || grant.RootID != writeRoot || !grant.CanWrite() {
			return ErrInvalidParent
		}
	}
	if err := s.forbidCycle(ctx, tx, n.ID, *parentID); err != nil {
		return err
	}
	// Most accounts share nothing; skip both tree walks for them.
	var sharesFolders bool
	if err := tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM folder_keys WHERE owner_user_id=?)", n.OwnerID).Scan(&sharesFolders); err != nil || !sharesFolders {
		return err
	}
	hasKeyed, err := access.SubtreeHasKeyedFolder(ctx, tx, n.ID)
	if err != nil || !hasKeyed {
		return err
	}
	if outer, err := access.NearestKeyedFolder(ctx, tx, *parentID); err != nil {
		return err
	} else if outer != "" {
		return access.ErrNestedSharedFolder
	}
	return nil
}

// directoryOwner returns the owner of an existing, non-deleted directory.
func (s *Service) directoryOwner(ctx context.Context, tx *sql.Tx, nodeID string) (string, error) {
	var ownerID, nodeType string
	var deletedAt sql.NullString
	err := tx.QueryRowContext(ctx, "SELECT owner_id, node_type, deleted_at FROM nodes WHERE id = ?", nodeID).Scan(&ownerID, &nodeType, &deletedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrInvalidParent
	}
	if err != nil {
		return "", err
	}
	if nodeType != "DIRECTORY" || deletedAt.Valid {
		return "", ErrInvalidParent
	}
	return ownerID, nil
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

// replayIfProcessed returns the recorded result of an already applied
// operation. Operation IDs are global keys, so one recorded by another
// account or for a different mutation is rejected instead of replayed.
func (s *Service) replayIfProcessed(ctx context.Context, tx *sql.Tx, operationID, userID, operationType string) (*processedResult, error) {
	var payload []byte
	var recordedUser, recordedType string
	err := tx.QueryRowContext(ctx, "SELECT user_id,operation_type,result_payload FROM processed_operations WHERE operation_id=?", operationID).
		Scan(&recordedUser, &recordedType, &payload)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if recordedUser != userID || recordedType != operationType {
		return nil, apierror.NewValidation("operation ID has already been used")
	}
	fields := strings.SplitN(string(payload), ":", 2)
	if len(fields) != 2 || uuid.Validate(fields[0]) != nil {
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

// validUUID accepts only the canonical lowercase, hyphenated spelling so
// one opaque ID can never be stored under several equivalent forms.
func validUUID(v string) bool {
	parsed, err := uuid.Parse(v)
	return err == nil && parsed.String() == v
}
func nullableString(v *string) any {
	if v == nil {
		return nil
	}
	return *v
}

// MaxRekeyItems bounds one rekey batch so a single request cannot hold
// SQLite's write lock for long; clients send a large subtree in pages.
const MaxRekeyItems = 200

// maxRekeyVersions bounds the file versions one rekey item may rewrap. The
// version retention policy keeps far fewer than this per file.
const maxRekeyVersions = 256

// RekeyVersion is one file version's File DEK rewrapped under a new key.
type RekeyVersion struct {
	ID             string
	WrappedFileKey []byte
	KeyScopeID     string
	KeyVersion     int
}

// RekeyItem re-encrypts one node's metadata and rewraps its file versions.
type RekeyItem struct {
	NodeID             string
	ExpectedRevision   int64
	MetadataCiphertext []byte
	MetadataKeyVersion int
	MetadataKeyScopeID string
	Versions           []RekeyVersion
}

type RekeyInput struct {
	UserID, DeviceID string
	Items            []RekeyItem
}

// Rekey moves existing nodes into another key scope (ADR-023): when a
// folder is first shared, everything below it must be readable with that
// folder's key instead of the owner's personal Vault Key. The owner's
// client re-encrypts each node's metadata and rewraps every File DEK
// locally; ciphertext blobs never change. Only the owner may rekey, the
// batch is atomic, and every node is checked against its expected revision
// so a concurrent change is never overwritten with stale metadata. A
// retried batch that already applied fails with a revision conflict, which
// the client resolves by re-reading the nodes.
func (s *Service) Rekey(ctx context.Context, in RekeyInput) ([]Node, error) {
	if len(in.Items) == 0 || len(in.Items) > MaxRekeyItems {
		return nil, apierror.NewValidation(fmt.Sprintf("a rekey batch needs 1 to %d nodes", MaxRekeyItems))
	}
	seen := make(map[string]bool, len(in.Items))
	for _, item := range in.Items {
		if !validUUID(item.NodeID) || seen[item.NodeID] || len(item.MetadataCiphertext) == 0 || len(item.MetadataCiphertext) > 1<<17 || len(item.Versions) > maxRekeyVersions {
			return nil, apierror.NewValidation("rekey items need unique node IDs, encrypted metadata, and a bounded version list")
		}
		seen[item.NodeID] = true
		for _, version := range item.Versions {
			if !validUUID(version.ID) || len(version.WrappedFileKey) == 0 || len(version.WrappedFileKey) > 1024 {
				return nil, apierror.NewValidation("rekeyed file versions need an ID and a wrapped file key")
			}
		}
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if err := s.validateDeviceOwnership(ctx, tx, in.UserID, in.DeviceID); err != nil {
		return nil, err
	}
	now := s.now().UTC().Format(time.RFC3339Nano)
	for _, item := range in.Items {
		current, err := s.lockNode(ctx, tx, item.NodeID)
		if err != nil {
			return nil, err
		}
		if current.OwnerID != in.UserID {
			return nil, ErrForbidden
		}
		if current.Revision != item.ExpectedRevision {
			return nil, ErrRevisionConflict
		}
		if err := access.ValidateKeyScope(ctx, tx, current.OwnerID, in.UserID, "", item.MetadataKeyScopeID, item.MetadataKeyVersion); err != nil {
			return nil, err
		}
		for _, version := range item.Versions {
			if err := access.ValidateKeyScope(ctx, tx, current.OwnerID, in.UserID, "", version.KeyScopeID, version.KeyVersion); err != nil {
				return nil, err
			}
			result, err := tx.ExecContext(ctx, `UPDATE file_versions SET wrapped_file_key=?, key_scope_id=?, key_version=? WHERE id=? AND node_id=?`,
				version.WrappedFileKey, version.KeyScopeID, version.KeyVersion, version.ID, item.NodeID)
			if err != nil {
				return nil, fmt.Errorf("rewrap file version: %w", err)
			}
			if affected, err := result.RowsAffected(); err != nil {
				return nil, err
			} else if affected != 1 {
				return nil, apierror.NewValidation("a rekeyed file version does not belong to its node")
			}
		}
		revision, err := s.recordChange(ctx, tx, current.OwnerID, item.NodeID, "UPDATE")
		if err != nil {
			return nil, err
		}
		if _, err := tx.ExecContext(ctx, `UPDATE nodes SET metadata_ciphertext=?, metadata_key_version=?, metadata_key_scope_id=?, revision=?, updated_at=? WHERE id=?`,
			item.MetadataCiphertext, item.MetadataKeyVersion, access.StoredScope(item.MetadataKeyScopeID, current.OwnerID), revision, now, item.NodeID); err != nil {
			return nil, fmt.Errorf("rekey node: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	out := make([]Node, 0, len(in.Items))
	for _, item := range in.Items {
		n, err := s.Get(ctx, in.UserID, item.NodeID)
		if err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	return out, nil
}
