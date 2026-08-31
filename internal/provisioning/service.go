// Package provisioning stores and delivers the encrypted key envelopes that
// grant a new trusted device access to a user's vault (ADR-012). The server
// only ever handles envelope_ciphertext as an opaque blob: it cannot unwrap
// it and never sees a vault key, folder key, or file DEK in the clear.
package provisioning

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/homebox/homebox/internal/apierror"
)

var ErrNotFound = errors.New("no key envelope found for this device")

type Envelope struct {
	ID             string
	VaultID        string
	TargetUserID   string
	TargetDeviceID string
	KeyVersion     int
	Ciphertext     []byte
	CreatedAt      time.Time
}

type Service struct {
	db  *sql.DB
	now func() time.Time
}

func New(db *sql.DB) *Service { return &Service{db: db, now: time.Now} }

// Upload records an envelope a trusted device produced for targetDeviceID.
// Callers must authorize that the target device belongs to the same user
// account before calling this; the service itself only enforces shape, not
// cross-user access rules (those live in the HTTP layer alongside the rest
// of ACL enforcement, matching §16.3's split between server ACL and
// cryptographic authorization).
func (s *Service) Upload(ctx context.Context, vaultID, targetUserID, targetDeviceID string, keyVersion int, ciphertext []byte) (Envelope, error) {
	if vaultID == "" || targetUserID == "" || targetDeviceID == "" || keyVersion < 1 {
		return Envelope{}, apierror.NewValidation("vault id, target user id, target device id, and key version are required")
	}
	if len(ciphertext) == 0 || len(ciphertext) > 1<<20 {
		return Envelope{}, apierror.NewValidation("envelope ciphertext is required and must be reasonably sized")
	}
	e := Envelope{
		ID: uuid.NewString(), VaultID: vaultID, TargetUserID: targetUserID, TargetDeviceID: targetDeviceID,
		KeyVersion: keyVersion, Ciphertext: ciphertext, CreatedAt: s.now().UTC(),
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO vault_key_envelopes
		(id,vault_id,target_user_id,target_device_id,key_version,envelope_ciphertext,created_at)
		VALUES (?,?,?,?,?,?,?)`,
		e.ID, e.VaultID, e.TargetUserID, e.TargetDeviceID, e.KeyVersion, e.Ciphertext, e.CreatedAt.Format(time.RFC3339Nano))
	if err != nil {
		return Envelope{}, err
	}
	return e, nil
}

// Latest returns the most recently uploaded, non-revoked envelope addressed
// to a device so a newly provisioned device can fetch exactly the one it
// needs.
func (s *Service) Latest(ctx context.Context, targetDeviceID string) (Envelope, error) {
	var e Envelope
	var createdAt string
	err := s.db.QueryRowContext(ctx, `SELECT id,vault_id,target_user_id,target_device_id,key_version,envelope_ciphertext,created_at
		FROM vault_key_envelopes WHERE target_device_id = ? AND revoked_at IS NULL ORDER BY created_at DESC LIMIT 1`, targetDeviceID).
		Scan(&e.ID, &e.VaultID, &e.TargetUserID, &e.TargetDeviceID, &e.KeyVersion, &e.Ciphertext, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Envelope{}, ErrNotFound
	}
	if err != nil {
		return Envelope{}, err
	}
	e.CreatedAt, err = time.Parse(time.RFC3339Nano, createdAt)
	return e, err
}

// ActiveEnvelopeDeviceIDs returns the set of targetUserID's device IDs that
// currently hold a non-revoked vault-key envelope. This is the only reliable
// "has this device actually been granted vault access" signal: a device can
// authenticate and even read the (still-undecryptable) sync feed before ever
// receiving one, so callers must not infer approval from login or sync
// activity alone.
func (s *Service) ActiveEnvelopeDeviceIDs(ctx context.Context, targetUserID string) (map[string]bool, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT DISTINCT target_device_id FROM vault_key_envelopes
		WHERE target_user_id = ? AND revoked_at IS NULL AND target_device_id IS NOT NULL`, targetUserID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := map[string]bool{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		result[id] = true
	}
	return result, rows.Err()
}
