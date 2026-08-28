// Package sync reads the global sync_changes feed (ADR-005) that
// internal/nodes and internal/uploads already write to. It contains no
// mutation logic of its own — it only serves paged, authorization-filtered
// slices of the feed a client can apply after decrypting each row's
// opaque/ciphertext payload locally.
package sync

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

var ErrInvalidCursor = errors.New("sync cursor is invalid")

type Change struct {
	Revision  int64
	NodeID    *string
	Operation string
	Payload   []byte
	CreatedAt time.Time
}

type Page struct {
	Changes   []Change
	NextAfter int64
	HasMore   bool
}

type Service struct {
	db          *sql.DB
	defaultSize int
	maxSize     int
}

func New(db *sql.DB, defaultPageSize, maxPageSize int) *Service {
	return &Service{db: db, defaultSize: defaultPageSize, maxSize: maxPageSize}
}

// Changes returns up to pageSize changes visible to userID strictly after
// afterRevision, ordered by revision. A returned Page.HasMore of true means
// the caller should request another page starting at Page.NextAfter rather
// than assuming it has caught up.
//
// Filtering by user_scope_id is today's whole authorization boundary: a
// change is visible to a user only if internal/nodes or internal/uploads
// stamped that user's ID onto it when the mutation happened. Sharing
// (spec §28) will need to widen this once a change can be visible to more
// than one account.
func (s *Service) Changes(ctx context.Context, userID string, afterRevision int64, pageSize int) (Page, error) {
	if afterRevision < 0 {
		return Page{}, ErrInvalidCursor
	}
	if pageSize <= 0 {
		pageSize = s.defaultSize
	}
	if pageSize > s.maxSize {
		pageSize = s.maxSize
	}

	rows, err := s.db.QueryContext(ctx, `SELECT revision,node_id,operation,payload_ciphertext,created_at
		FROM sync_changes WHERE user_scope_id = ? AND revision > ? ORDER BY revision LIMIT ?`,
		userID, afterRevision, pageSize+1)
	if err != nil {
		return Page{}, err
	}
	defer rows.Close()

	var changes []Change
	for rows.Next() {
		var c Change
		var nodeID sql.NullString
		var createdAt string
		if err := rows.Scan(&c.Revision, &nodeID, &c.Operation, &c.Payload, &createdAt); err != nil {
			return Page{}, err
		}
		if nodeID.Valid {
			c.NodeID = &nodeID.String
		}
		if c.CreatedAt, err = time.Parse(time.RFC3339Nano, createdAt); err != nil {
			return Page{}, err
		}
		changes = append(changes, c)
	}
	if err := rows.Err(); err != nil {
		return Page{}, err
	}

	page := Page{Changes: changes, NextAfter: afterRevision}
	if len(changes) > pageSize {
		page.Changes = changes[:pageSize]
		page.HasMore = true
	}
	if len(page.Changes) > 0 {
		page.NextAfter = page.Changes[len(page.Changes)-1].Revision
	}
	return page, nil
}
