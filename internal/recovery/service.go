// Package recovery stores each account's client-encrypted recovery bundle
// (spec §10.12, §32.2). The bundle is opaque ciphertext: it can only be
// opened with the user's Recovery Secret, which never reaches the server, so
// keeping it here lets a clean device recover the vault without giving the
// server any decryption capability.
package recovery

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/homebox/homebox/internal/apierror"
	"github.com/homebox/homebox/internal/deviceauth"
)

// MaxBundleSize bounds the opaque bundle. The current client format is a few
// hundred bytes; the headroom only allows for future format versions.
const MaxBundleSize = 4096

var (
	ErrNotFound         = errors.New("no recovery bundle is stored for this account")
	ErrIdentityConflict = errors.New("recovery bundle is not signed by this account's identity")
)

type Bundle struct {
	Bundle            []byte
	UpdatedAt         time.Time
	UpdatedByDeviceID string
}

type Service struct {
	db  *sql.DB
	now func() time.Time
}

func New(db *sql.DB) *Service { return &Service{db: db, now: time.Now} }

// Get returns the account's current recovery bundle.
func (s *Service) Get(ctx context.Context, userID string) (Bundle, error) {
	var b Bundle
	var updatedAt string
	err := s.db.QueryRowContext(ctx, `SELECT bundle,updated_at,updated_by_device_id FROM recovery_bundles WHERE user_id=?`, userID).
		Scan(&b.Bundle, &updatedAt, &b.UpdatedByDeviceID)
	if errors.Is(err, sql.ErrNoRows) {
		return Bundle{}, ErrNotFound
	}
	if err != nil {
		return Bundle{}, err
	}
	if b.UpdatedAt, err = time.Parse(time.RFC3339Nano, updatedAt); err != nil {
		return Bundle{}, err
	}
	return b, nil
}

// Put stores or replaces the account's recovery bundle. The bundle must be
// signed by the account's Ed25519 identity, which only vault-unlocked
// clients can derive. The expected identity is the one already established
// by the account's signed device certificates or, before any exists, by a
// previously stored bundle; only a brand-new account trusts its first
// upload. This keeps a stolen session without the Vault Key from replacing
// the bundle and silently breaking recovery.
func (s *Service) Put(ctx context.Context, userID, deviceID string, bundle, accountPublicKey, signature []byte) error {
	if len(bundle) == 0 || len(bundle) > MaxBundleSize {
		return apierror.NewValidation("recovery bundle is required and must be at most 4096 bytes")
	}
	if deviceauth.VerifyRecoveryBundle(accountPublicKey, signature, userID, bundle) != nil {
		return apierror.NewValidation("recovery bundle signature is invalid")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	expected, err := establishedIdentity(ctx, tx, userID)
	if err != nil {
		return err
	}
	if expected != nil && !bytes.Equal(expected, accountPublicKey) {
		return ErrIdentityConflict
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO recovery_bundles
		(user_id,bundle,account_identity_public_key,signature,updated_at,updated_by_device_id) VALUES (?,?,?,?,?,?)
		ON CONFLICT(user_id) DO UPDATE SET bundle=excluded.bundle,
			account_identity_public_key=excluded.account_identity_public_key, signature=excluded.signature,
			updated_at=excluded.updated_at, updated_by_device_id=excluded.updated_by_device_id`,
		userID, bundle, accountPublicKey, signature, s.now().UTC().Format(time.RFC3339Nano), deviceID); err != nil {
		return err
	}
	return tx.Commit()
}

// establishedIdentity returns the account identity public key the server
// already trusts for userID, or nil when none has been recorded yet.
func establishedIdentity(ctx context.Context, tx *sql.Tx, userID string) ([]byte, error) {
	var key []byte
	err := tx.QueryRowContext(ctx, `SELECT account_identity_public_key FROM vault_key_envelopes
		WHERE target_user_id=? AND signature_version IS NOT NULL AND revoked_at IS NULL
		ORDER BY created_at,id LIMIT 1`, userID).Scan(&key)
	if err == nil {
		return key, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	err = tx.QueryRowContext(ctx, `SELECT account_identity_public_key FROM recovery_bundles WHERE user_id=?`, userID).Scan(&key)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return key, err
}
