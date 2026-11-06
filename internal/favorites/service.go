// Package favorites stores which nodes each account marked as a favorite
// (spec §29). A favorite is an opaque (user, node) relationship; the server
// learns nothing about the node beyond what it already knows.
package favorites

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/homebox/homebox/internal/access"
	"github.com/homebox/homebox/internal/apierror"
)

// ErrNotFound is returned for a node the account cannot see: missing, in
// Trash, or neither owned nor shared with it.
var ErrNotFound = errors.New("node not found")

// MaxFavorites bounds how many favorites one account may keep.
const MaxFavorites = 10000

type Favorite struct {
	NodeID    string
	CreatedAt time.Time
}

type Service struct {
	db  *sql.DB
	now func() time.Time
}

func New(db *sql.DB) *Service { return &Service{db: db, now: time.Now} }

// Add marks nodeID as a favorite of userID. Adding an existing favorite is
// a no-op, so retries are safe.
func (s *Service) Add(ctx context.Context, userID, nodeID string) error {
	if !access.ValidUUID(userID) || !access.ValidUUID(nodeID) {
		return apierror.NewValidation("user and node IDs must be valid UUIDs")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := requireVisible(ctx, tx, userID, nodeID); err != nil {
		return err
	}
	var count int
	if err := tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM favorites WHERE user_id=?", userID).Scan(&count); err != nil {
		return err
	}
	if count >= MaxFavorites {
		return apierror.NewValidation("too many favorites; remove some first")
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO favorites (user_id,node_id,created_at) VALUES (?,?,?)
		ON CONFLICT(user_id,node_id) DO NOTHING`, userID, nodeID, s.now().UTC().Format(time.RFC3339Nano)); err != nil {
		return err
	}
	return tx.Commit()
}

// Remove unmarks nodeID. Removing a favorite that does not exist is a
// no-op, so a node that was purged or unshared can always be unmarked.
func (s *Service) Remove(ctx context.Context, userID, nodeID string) error {
	if !access.ValidUUID(userID) || !access.ValidUUID(nodeID) {
		return apierror.NewValidation("user and node IDs must be valid UUIDs")
	}
	_, err := s.db.ExecContext(ctx, "DELETE FROM favorites WHERE user_id=? AND node_id=?", userID, nodeID)
	return err
}

// List returns userID's favorites that it can still see, newest first. A
// favorite of a node now in Trash or no longer shared stays stored, so it
// comes back when the node does, but is not listed.
func (s *Service) List(ctx context.Context, userID string) ([]Favorite, error) {
	if !access.ValidUUID(userID) {
		return nil, apierror.NewValidation("user ID must be a valid UUID")
	}
	rows, err := s.db.QueryContext(ctx, `SELECT f.node_id,f.created_at,n.owner_id FROM favorites f
		JOIN nodes n ON n.id=f.node_id
		WHERE f.user_id=? AND n.deleted_at IS NULL ORDER BY f.created_at DESC`, userID)
	if err != nil {
		return nil, err
	}
	type row struct {
		favorite Favorite
		ownerID  string
	}
	var candidates []row
	for rows.Next() {
		var r row
		var created string
		if err := rows.Scan(&r.favorite.NodeID, &created, &r.ownerID); err != nil {
			rows.Close()
			return nil, err
		}
		if r.favorite.CreatedAt, err = time.Parse(time.RFC3339Nano, created); err != nil {
			rows.Close()
			return nil, err
		}
		candidates = append(candidates, r)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	out := make([]Favorite, 0, len(candidates))
	for _, c := range candidates {
		if c.ownerID != userID {
			if _, shared, err := access.ShareGrant(ctx, s.db, userID, c.favorite.NodeID); err != nil {
				return nil, err
			} else if !shared {
				continue
			}
		}
		out = append(out, c.favorite)
	}
	return out, nil
}

// requireVisible accepts a live node the user owns or reaches through an
// active share.
func requireVisible(ctx context.Context, q access.Querier, userID, nodeID string) error {
	var ownerID string
	var deletedAt sql.NullString
	err := q.QueryRowContext(ctx, "SELECT owner_id,deleted_at FROM nodes WHERE id=?", nodeID).Scan(&ownerID, &deletedAt)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && deletedAt.Valid) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if ownerID == userID {
		return nil
	}
	_, shared, err := access.ShareGrant(ctx, q, userID, nodeID)
	if err != nil {
		return err
	}
	if !shared {
		return ErrNotFound
	}
	return nil
}
