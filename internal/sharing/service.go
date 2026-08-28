// Package sharing stores Family Vault read-only folder grants and opaque
// recipient-device key envelopes. It never decrypts an envelope or metadata.
package sharing

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/homebox/homebox/internal/apierror"
)

var (
	ErrNotFound       = errors.New("share not found")
	ErrForbidden      = errors.New("share is not owned by this account")
	ErrAlreadyShared  = errors.New("folder is already shared with this account")
	ErrTargetNotFound = errors.New("target family account or device was not found")
)

type DeviceEnvelope struct {
	TargetDeviceID string
	KeyVersion     int
	Ciphertext     []byte
}

type Share struct {
	ID, NodeID, OwnerUserID, TargetUserID, Permission string
	CreatedAt                                         time.Time
	Envelopes                                         []DeviceEnvelope
}

type CreateInput struct {
	OwnerUserID, OwnerDeviceID, OperationID, NodeID, TargetUserID string
	Permission                                                    string
	Envelopes                                                     []DeviceEnvelope
}

type Service struct {
	db  *sql.DB
	now func() time.Time
}

func New(db *sql.DB) *Service { return &Service{db: db, now: time.Now} }

// CreateReadGrant shares one non-deleted folder with every recipient device
// for which the owner provided a distinct, client-encrypted envelope. Only
// READ is accepted until shared mutation and conflict semantics are complete.
func (s *Service) CreateReadGrant(ctx context.Context, in CreateInput) (Share, error) {
	if !validUUID(in.OwnerUserID) || !validUUID(in.OwnerDeviceID) || !validUUID(in.OperationID) || !validUUID(in.NodeID) || !validUUID(in.TargetUserID) {
		return Share{}, apierror.NewValidation("share user, device, operation, and folder IDs must be valid UUIDs")
	}
	if in.OwnerUserID == in.TargetUserID || in.Permission != "READ" || len(in.Envelopes) == 0 || len(in.Envelopes) > 32 {
		return Share{}, apierror.NewValidation("a share needs a different recipient, READ permission, and 1 to 32 device envelopes")
	}
	seen := map[string]bool{}
	for _, envelope := range in.Envelopes {
		if !validUUID(envelope.TargetDeviceID) || envelope.KeyVersion < 1 || len(envelope.Ciphertext) == 0 || len(envelope.Ciphertext) > 1<<20 || seen[envelope.TargetDeviceID] {
			return Share{}, apierror.NewValidation("share device envelopes must be unique, versioned, and reasonably sized")
		}
		seen[envelope.TargetDeviceID] = true
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Share{}, err
	}
	defer tx.Rollback()
	if replay, err := s.replay(ctx, tx, in); err != nil {
		return Share{}, err
	} else if replay != nil {
		tx.Rollback()
		return s.GetOutgoing(ctx, in.OwnerUserID, *replay)
	}
	if err := requireActiveDevice(ctx, tx, in.OwnerUserID, in.OwnerDeviceID); err != nil {
		return Share{}, err
	}
	var nodeType string
	var deleted sql.NullString
	if err := tx.QueryRowContext(ctx, "SELECT node_type,deleted_at FROM nodes WHERE id=? AND owner_id=?", in.NodeID, in.OwnerUserID).Scan(&nodeType, &deleted); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Share{}, ErrForbidden
		}
		return Share{}, err
	}
	if nodeType != "DIRECTORY" || deleted.Valid {
		return Share{}, apierror.NewValidation("only a non-deleted folder can be shared")
	}
	var active bool
	if err := tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM users WHERE id=? AND status='ACTIVE')", in.TargetUserID).Scan(&active); err != nil {
		return Share{}, err
	}
	if !active {
		return Share{}, ErrTargetNotFound
	}
	var alreadyShared bool
	if err := tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM shares WHERE node_id=? AND target_user_id=? AND revoked_at IS NULL)", in.NodeID, in.TargetUserID).Scan(&alreadyShared); err != nil {
		return Share{}, err
	}
	if alreadyShared {
		return Share{}, ErrAlreadyShared
	}
	for _, envelope := range in.Envelopes {
		if err := requireActiveDevice(ctx, tx, in.TargetUserID, envelope.TargetDeviceID); err != nil {
			return Share{}, ErrTargetNotFound
		}
	}
	share := Share{ID: uuid.NewString(), NodeID: in.NodeID, OwnerUserID: in.OwnerUserID, TargetUserID: in.TargetUserID, Permission: "READ", CreatedAt: s.now().UTC(), Envelopes: in.Envelopes}
	// shares.key_envelope predates device-specific sharing. It remains filled
	// with an opaque copy for schema compatibility; readers use envelopes.
	if _, err := tx.ExecContext(ctx, `INSERT INTO shares (id,node_id,owner_user_id,target_user_id,permission,key_envelope,key_version,created_at,created_by)
		VALUES (?,?,?,?,?,?,?, ?,?)`, share.ID, share.NodeID, share.OwnerUserID, share.TargetUserID, share.Permission, in.Envelopes[0].Ciphertext, in.Envelopes[0].KeyVersion, share.CreatedAt.Format(time.RFC3339Nano), in.OwnerUserID); err != nil {
		if isUniqueConstraint(err) {
			return Share{}, ErrAlreadyShared
		}
		return Share{}, fmt.Errorf("create folder share: %w", err)
	}
	for _, envelope := range in.Envelopes {
		if _, err := tx.ExecContext(ctx, `INSERT INTO share_device_envelopes (id,share_id,target_device_id,key_version,envelope_ciphertext,created_at)
			VALUES (?,?,?,?,?,?)`, uuid.NewString(), share.ID, envelope.TargetDeviceID, envelope.KeyVersion, envelope.Ciphertext, share.CreatedAt.Format(time.RFC3339Nano)); err != nil {
			return Share{}, fmt.Errorf("create recipient envelope: %w", err)
		}
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO processed_operations (operation_id,user_id,device_id,operation_type,result_code,result_payload,created_at,expires_at)
		VALUES (?,?,?,'SHARE_CREATE','OK',?,?,?)`, in.OperationID, in.OwnerUserID, in.OwnerDeviceID, []byte(share.ID), share.CreatedAt.Format(time.RFC3339Nano), share.CreatedAt.Add(30*24*time.Hour).Format(time.RFC3339Nano)); err != nil {
		return Share{}, err
	}
	if err := tx.Commit(); err != nil {
		return Share{}, err
	}
	return share, nil
}

func (s *Service) ListIncoming(ctx context.Context, userID, deviceID string) ([]Share, error) {
	if !validUUID(userID) || !validUUID(deviceID) {
		return nil, apierror.NewValidation("user and device IDs must be valid UUIDs")
	}
	rows, err := s.db.QueryContext(ctx, `SELECT sh.id,sh.node_id,sh.owner_user_id,sh.target_user_id,sh.permission,sh.created_at,e.target_device_id,e.key_version,e.envelope_ciphertext
		FROM shares sh JOIN share_device_envelopes e ON e.share_id=sh.id
		WHERE sh.target_user_id=? AND e.target_device_id=? AND sh.revoked_at IS NULL AND e.revoked_at IS NULL ORDER BY sh.created_at`, userID, deviceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanShares(rows)
}

func (s *Service) GetOutgoing(ctx context.Context, ownerUserID, shareID string) (Share, error) {
	if !validUUID(ownerUserID) || !validUUID(shareID) {
		return Share{}, apierror.NewValidation("owner and share IDs must be valid UUIDs")
	}
	rows, err := s.db.QueryContext(ctx, `SELECT sh.id,sh.node_id,sh.owner_user_id,sh.target_user_id,sh.permission,sh.created_at,e.target_device_id,e.key_version,e.envelope_ciphertext
		FROM shares sh JOIN share_device_envelopes e ON e.share_id=sh.id
		WHERE sh.id=? AND sh.owner_user_id=? AND sh.revoked_at IS NULL AND e.revoked_at IS NULL ORDER BY e.created_at`, shareID, ownerUserID)
	if err != nil {
		return Share{}, err
	}
	defer rows.Close()
	shares, err := scanShares(rows)
	if err != nil {
		return Share{}, err
	}
	if len(shares) == 0 {
		return Share{}, ErrNotFound
	}
	return shares[0], nil
}

func (s *Service) ListOutgoing(ctx context.Context, ownerUserID string) ([]Share, error) {
	if !validUUID(ownerUserID) {
		return nil, apierror.NewValidation("owner ID must be a valid UUID")
	}
	rows, err := s.db.QueryContext(ctx, `SELECT sh.id,sh.node_id,sh.owner_user_id,sh.target_user_id,sh.permission,sh.created_at,e.target_device_id,e.key_version,e.envelope_ciphertext
		FROM shares sh JOIN share_device_envelopes e ON e.share_id=sh.id
		WHERE sh.owner_user_id=? AND sh.revoked_at IS NULL AND e.revoked_at IS NULL ORDER BY sh.created_at,e.created_at`, ownerUserID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanShares(rows)
}

func (s *Service) Revoke(ctx context.Context, ownerUserID, ownerDeviceID, shareID string) error {
	if !validUUID(ownerUserID) || !validUUID(ownerDeviceID) || !validUUID(shareID) {
		return apierror.NewValidation("owner, device, and share IDs must be valid UUIDs")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := requireActiveDevice(ctx, tx, ownerUserID, ownerDeviceID); err != nil {
		return err
	}
	now := s.now().UTC().Format(time.RFC3339Nano)
	result, err := tx.ExecContext(ctx, "UPDATE shares SET revoked_at=? WHERE id=? AND owner_user_id=? AND revoked_at IS NULL", now, shareID, ownerUserID)
	if err != nil {
		return err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if affected == 0 {
		var exists bool
		if err := tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM shares WHERE id=? AND owner_user_id=?)", shareID, ownerUserID).Scan(&exists); err != nil {
			return err
		}
		if !exists {
			return ErrNotFound
		}
		return tx.Commit()
	}
	if _, err := tx.ExecContext(ctx, "UPDATE share_device_envelopes SET revoked_at=? WHERE share_id=? AND revoked_at IS NULL", now, shareID); err != nil {
		return err
	}
	return tx.Commit()
}

func scanShares(rows *sql.Rows) ([]Share, error) {
	byID := map[string]*Share{}
	var order []string
	for rows.Next() {
		var share Share
		var created string
		var envelope DeviceEnvelope
		if err := rows.Scan(&share.ID, &share.NodeID, &share.OwnerUserID, &share.TargetUserID, &share.Permission, &created, &envelope.TargetDeviceID, &envelope.KeyVersion, &envelope.Ciphertext); err != nil {
			return nil, err
		}
		createdAt, err := time.Parse(time.RFC3339Nano, created)
		if err != nil {
			return nil, err
		}
		share.CreatedAt = createdAt
		current := byID[share.ID]
		if current == nil {
			byID[share.ID] = &share
			current = &share
			order = append(order, share.ID)
		}
		current.Envelopes = append(current.Envelopes, envelope)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	out := make([]Share, 0, len(order))
	for _, id := range order {
		out = append(out, *byID[id])
	}
	return out, nil
}

func (s *Service) replay(ctx context.Context, tx *sql.Tx, in CreateInput) (*string, error) {
	var userID, deviceID, operationType string
	var payload []byte
	err := tx.QueryRowContext(ctx, "SELECT user_id,device_id,operation_type,result_payload FROM processed_operations WHERE operation_id=?", in.OperationID).Scan(&userID, &deviceID, &operationType, &payload)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if userID != in.OwnerUserID || deviceID != in.OwnerDeviceID || operationType != "SHARE_CREATE" || !validUUID(string(payload)) {
		return nil, apierror.NewValidation("operation ID has already been used")
	}
	id := string(payload)
	return &id, nil
}
func requireActiveDevice(ctx context.Context, tx *sql.Tx, userID, deviceID string) error {
	var ok bool
	err := tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM devices WHERE id=? AND user_id=? AND revoked_at IS NULL)", deviceID, userID).Scan(&ok)
	if err != nil {
		return err
	}
	if !ok {
		return ErrForbidden
	}
	return nil
}
func validUUID(v string) bool { _, err := uuid.Parse(v); return err == nil }
func isUniqueConstraint(err error) bool {
	return strings.Contains(strings.ToLower(err.Error()), "unique constraint")
}
