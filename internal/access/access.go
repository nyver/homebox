// Package access holds the Family Vault authorization and key-scope rules
// shared by internal/nodes, internal/uploads, and internal/sharing (spec
// §28, ADR-023). It never sees plaintext: it only reasons about opaque node
// IDs, share rows, and which folder key a client declared it used.
package access

import (
	"context"
	"database/sql"
	"errors"

	"github.com/google/uuid"
	"github.com/homebox/homebox/internal/apierror"
)

const (
	PermissionRead      = "READ"
	PermissionReadWrite = "READ_WRITE"
)

// ErrNestedSharedFolder rejects a folder key or move that would place one
// shared folder inside another. Keeping shared folders disjoint means every
// node has exactly one nearest key scope, so a recipient of the outer folder
// is never handed descendants it cannot decrypt.
var ErrNestedSharedFolder = apierror.NewValidation("a shared folder cannot contain or be placed inside another shared folder")

// Querier is satisfied by both *sql.DB and *sql.Tx.
type Querier interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// Grant describes the active share through which a non-owner reaches a node.
type Grant struct {
	RootID     string
	Permission string
}

// CanWrite reports whether the grant allows creating, changing, or deleting
// nodes below its root.
func (g Grant) CanWrite() bool { return g.Permission == PermissionReadWrite }

// ShareGrant returns the nearest active share of nodeID or one of its
// ancestors whose recipient is userID. found is false when there is none,
// and also when the node or any folder between it and that share root is in
// Trash: a recipient loses a subtree the owner deleted, exactly as the
// owner's own listings hide it. A database error is returned as such rather
// than as "no share", so it surfaces as an internal error, not a 403.
func ShareGrant(ctx context.Context, q Querier, userID, nodeID string) (grant Grant, found bool, err error) {
	var rootID, permission sql.NullString
	err = q.QueryRowContext(ctx, `WITH RECURSIVE ancestors(id,parent_id,deleted_at,depth) AS (
		SELECT id,parent_id,deleted_at,0 FROM nodes WHERE id=?
		UNION ALL SELECT n.id,n.parent_id,n.deleted_at,a.depth+1 FROM nodes n JOIN ancestors a ON a.parent_id=n.id
	), nearest AS (
		SELECT a.id,a.depth,sh.permission FROM ancestors a JOIN shares sh ON sh.node_id=a.id
		WHERE sh.target_user_id=? AND sh.revoked_at IS NULL ORDER BY a.depth LIMIT 1
	) SELECT nearest.id,nearest.permission FROM nearest
		WHERE NOT EXISTS(SELECT 1 FROM ancestors a WHERE a.depth <= nearest.depth AND a.deleted_at IS NOT NULL)`,
		nodeID, userID).Scan(&rootID, &permission)
	if errors.Is(err, sql.ErrNoRows) {
		return Grant{}, false, nil
	}
	if err != nil {
		return Grant{}, false, err
	}
	return Grant{RootID: rootID.String, Permission: permission.String}, true, nil
}

// NearestKeyedFolder returns nodeID itself or its closest ancestor that has
// a folder key, or "" when the node lives in its owner's personal Vault.
func NearestKeyedFolder(ctx context.Context, q Querier, nodeID string) (string, error) {
	var folderID string
	err := q.QueryRowContext(ctx, `WITH RECURSIVE ancestors(id,parent_id,depth) AS (
		SELECT id,parent_id,0 FROM nodes WHERE id=?
		UNION ALL SELECT n.id,n.parent_id,a.depth+1 FROM nodes n JOIN ancestors a ON a.parent_id=n.id
	) SELECT a.id FROM ancestors a WHERE EXISTS(SELECT 1 FROM folder_keys k WHERE k.folder_id=a.id)
		ORDER BY a.depth LIMIT 1`, nodeID).Scan(&folderID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return folderID, err
}

// SubtreeHasKeyedFolder reports whether nodeID or any of its descendants,
// including ones in Trash, has a folder key.
func SubtreeHasKeyedFolder(ctx context.Context, q Querier, nodeID string) (bool, error) {
	var found bool
	err := q.QueryRowContext(ctx, `WITH RECURSIVE subtree(id) AS (
		SELECT id FROM nodes WHERE id=?
		UNION SELECT n.id FROM nodes n JOIN subtree s ON n.parent_id=s.id
	) SELECT EXISTS(SELECT 1 FROM subtree s JOIN folder_keys k ON k.folder_id=s.id)`, nodeID).Scan(&found)
	return found, err
}

// ValidateKeyScope checks the key a client declared for metadata or a File
// DEK it is about to store. scopeID is either the owner's own account ID
// (the personal Vault Key, which only the owner holds) or the ID of one of
// the owner's shared folders with an existing key of keyVersion. A
// non-owner writer must use the folder key of the share it writes through
// (writeRootID), so everything it adds stays readable by every member.
//
// The check cannot prove the ciphertext really uses that key; it keeps
// honest clients consistent, while AEAD context binding makes a lying
// client's content undecryptable rather than readable by anyone else.
func ValidateKeyScope(ctx context.Context, q Querier, ownerID, actorID, writeRootID, scopeID string, keyVersion int) error {
	if keyVersion < 1 {
		return apierror.NewValidation("a key version is required")
	}
	if scopeID == ownerID {
		if actorID != ownerID {
			return apierror.NewValidation("shared content must be encrypted with the shared folder's key")
		}
		return nil
	}
	if !ValidUUID(scopeID) {
		return apierror.NewValidation("key scope must be the owner's account or one of its shared folders")
	}
	if actorID != ownerID && scopeID != writeRootID {
		return apierror.NewValidation("shared content must be encrypted with the shared folder's key")
	}
	var exists bool
	if err := q.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM folder_keys WHERE folder_id=? AND key_version=? AND owner_user_id=?)",
		scopeID, keyVersion, ownerID).Scan(&exists); err != nil {
		return err
	}
	if !exists {
		return apierror.NewValidation("the declared folder key does not exist")
	}
	return nil
}

// StoredScope converts a declared scope into the nodes.metadata_key_scope_id
// column value: NULL for the owner's personal Vault, the folder ID otherwise.
func StoredScope(scopeID, ownerID string) any {
	if scopeID == "" || scopeID == ownerID {
		return nil
	}
	return scopeID
}

// ValidUUID accepts only the canonical lowercase, hyphenated spelling.
func ValidUUID(v string) bool {
	parsed, err := uuid.Parse(v)
	return err == nil && parsed.String() == v
}
