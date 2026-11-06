// Package sharing stores Family Vault folder grants, per-version folder keys
// wrapped for their owner, and opaque recipient-device key envelopes
// (spec §28, ADR-023). It never decrypts an envelope or metadata.
package sharing

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/homebox/homebox/internal/access"
	"github.com/homebox/homebox/internal/apierror"
)

var (
	ErrNotFound       = errors.New("share not found")
	ErrForbidden      = errors.New("share is not owned by this account")
	ErrAlreadyShared  = errors.New("folder is already shared with this account")
	ErrTargetNotFound = errors.New("target family account or device was not found")
	ErrKeyConflict    = errors.New("folder key version already exists with different content")
)

const (
	// maxEnvelopesPerRequest bounds one grant or envelope batch.
	maxEnvelopesPerRequest = 32
	maxEnvelopeSize        = 4096
	// ownerSignatureLength and ownerIdentityKeyLength are Ed25519 sizes.
	ownerSignatureLength   = 64
	ownerIdentityKeyLength = 32
)

// DeviceEnvelope is one folder key version encrypted for one recipient
// device. OwnerIdentityPublicKey and OwnerSignature let the recipient check
// that the owner's account identity, not the server, created it.
type DeviceEnvelope struct {
	TargetDeviceID         string
	KeyVersion             int
	Ciphertext             []byte
	OwnerIdentityPublicKey []byte
	OwnerSignature         []byte
}

type Share struct {
	ID, NodeID, OwnerUserID, TargetUserID, Permission string
	OwnerUsername, TargetUsername                     string
	CreatedAt                                         time.Time
	Envelopes                                         []DeviceEnvelope
}

type CreateInput struct {
	OwnerUserID, OwnerDeviceID, OperationID, NodeID, TargetUserID string
	Permission                                                    string
	Envelopes                                                     []DeviceEnvelope
}

// FolderKey is one version of a shared folder's key, wrapped by its owner's
// personal Vault Key so every trusted owner device can open it.
type FolderKey struct {
	FolderID      string
	KeyVersion    int
	OwnerEnvelope []byte
	CreatedAt     time.Time
}

type Service struct {
	db  *sql.DB
	now func() time.Time
}

func New(db *sql.DB) *Service { return &Service{db: db, now: time.Now} }

// CreateFolderKey stores the next version of a folder's key. Version 1
// turns a folder into a key scope; it is refused when the folder sits
// inside, or contains, another shared folder, so scopes never nest. A later
// version rotates the key after a member was removed (spec §28.3). Storing
// exactly the same envelope again is an idempotent retry.
func (s *Service) CreateFolderKey(ctx context.Context, ownerUserID, ownerDeviceID, folderID string, keyVersion int, envelope []byte) (FolderKey, error) {
	if !access.ValidUUID(ownerUserID) || !access.ValidUUID(ownerDeviceID) || !access.ValidUUID(folderID) {
		return FolderKey{}, apierror.NewValidation("owner, device, and folder IDs must be valid UUIDs")
	}
	if keyVersion < 1 || len(envelope) == 0 || len(envelope) > maxEnvelopeSize {
		return FolderKey{}, apierror.NewValidation("a folder key needs a positive version and a reasonably sized envelope")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return FolderKey{}, err
	}
	defer tx.Rollback()
	if err := requireActiveDevice(ctx, tx, ownerUserID, ownerDeviceID); err != nil {
		return FolderKey{}, err
	}
	if err := requireOwnedFolder(ctx, tx, ownerUserID, folderID); err != nil {
		return FolderKey{}, err
	}
	var existing []byte
	err = tx.QueryRowContext(ctx, "SELECT owner_envelope FROM folder_keys WHERE folder_id=? AND key_version=?", folderID, keyVersion).Scan(&existing)
	switch {
	case err == nil:
		if !bytes.Equal(existing, envelope) {
			return FolderKey{}, ErrKeyConflict
		}
		tx.Rollback()
		return s.folderKey(ctx, ownerUserID, folderID, keyVersion)
	case !errors.Is(err, sql.ErrNoRows):
		return FolderKey{}, err
	}
	var latest int
	if err := tx.QueryRowContext(ctx, "SELECT COALESCE(MAX(key_version),0) FROM folder_keys WHERE folder_id=?", folderID).Scan(&latest); err != nil {
		return FolderKey{}, err
	}
	if keyVersion != latest+1 {
		return FolderKey{}, apierror.NewValidation(fmt.Sprintf("the next key version of this folder is %d", latest+1))
	}
	if latest == 0 {
		if err := forbidNestedScope(ctx, tx, folderID); err != nil {
			return FolderKey{}, err
		}
	}
	now := s.now().UTC()
	if _, err := tx.ExecContext(ctx, `INSERT INTO folder_keys (folder_id,key_version,owner_user_id,owner_envelope,created_at,created_by_device_id)
		VALUES (?,?,?,?,?,?)`, folderID, keyVersion, ownerUserID, envelope, now.Format(time.RFC3339Nano), ownerDeviceID); err != nil {
		return FolderKey{}, fmt.Errorf("create folder key: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return FolderKey{}, err
	}
	return FolderKey{FolderID: folderID, KeyVersion: keyVersion, OwnerEnvelope: envelope, CreatedAt: now}, nil
}

// ListFolderKeys returns every folder key version the owner has created,
// including keys of purged folders that still encrypt surviving nodes.
func (s *Service) ListFolderKeys(ctx context.Context, ownerUserID string) ([]FolderKey, error) {
	if !access.ValidUUID(ownerUserID) {
		return nil, apierror.NewValidation("owner ID must be a valid UUID")
	}
	rows, err := s.db.QueryContext(ctx, `SELECT folder_id,key_version,owner_envelope,created_at FROM folder_keys
		WHERE owner_user_id=? ORDER BY folder_id,key_version`, ownerUserID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var keys []FolderKey
	for rows.Next() {
		key, err := scanFolderKey(rows)
		if err != nil {
			return nil, err
		}
		keys = append(keys, key)
	}
	return keys, rows.Err()
}

func (s *Service) folderKey(ctx context.Context, ownerUserID, folderID string, keyVersion int) (FolderKey, error) {
	return scanFolderKey(s.db.QueryRowContext(ctx, `SELECT folder_id,key_version,owner_envelope,created_at FROM folder_keys
		WHERE owner_user_id=? AND folder_id=? AND key_version=?`, ownerUserID, folderID, keyVersion))
}

type rowScanner interface{ Scan(dest ...any) error }

func scanFolderKey(row rowScanner) (FolderKey, error) {
	var key FolderKey
	var created string
	if err := row.Scan(&key.FolderID, &key.KeyVersion, &key.OwnerEnvelope, &created); err != nil {
		return FolderKey{}, err
	}
	createdAt, err := time.Parse(time.RFC3339Nano, created)
	if err != nil {
		return FolderKey{}, err
	}
	key.CreatedAt = createdAt
	return key, nil
}

// CreateGrant shares one non-deleted, already keyed folder with every
// recipient device for which the owner provided a distinct, signed,
// client-encrypted folder-key envelope. READ lets the recipient browse and
// download; READ_WRITE also lets it add, change, and delete content below
// the shared folder.
func (s *Service) CreateGrant(ctx context.Context, in CreateInput) (Share, error) {
	if !access.ValidUUID(in.OwnerUserID) || !access.ValidUUID(in.OwnerDeviceID) || !access.ValidUUID(in.OperationID) || !access.ValidUUID(in.NodeID) || !access.ValidUUID(in.TargetUserID) {
		return Share{}, apierror.NewValidation("share user, device, operation, and folder IDs must be valid UUIDs")
	}
	if in.Permission != access.PermissionRead && in.Permission != access.PermissionReadWrite {
		return Share{}, apierror.NewValidation("share permission must be READ or READ_WRITE")
	}
	if in.OwnerUserID == in.TargetUserID || len(in.Envelopes) == 0 || len(in.Envelopes) > maxEnvelopesPerRequest {
		return Share{}, apierror.NewValidation(fmt.Sprintf("a share needs a different recipient and 1 to %d device envelopes", maxEnvelopesPerRequest))
	}
	if err := validateEnvelopes(in.Envelopes); err != nil {
		return Share{}, err
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
	if err := requireOwnedFolder(ctx, tx, in.OwnerUserID, in.NodeID); err != nil {
		return Share{}, err
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
	if err := requireEnvelopeTargets(ctx, tx, in.NodeID, in.TargetUserID, in.Envelopes); err != nil {
		return Share{}, err
	}
	share := Share{ID: uuid.NewString(), NodeID: in.NodeID, OwnerUserID: in.OwnerUserID, TargetUserID: in.TargetUserID, Permission: in.Permission, CreatedAt: s.now().UTC(), Envelopes: in.Envelopes}
	// shares.key_envelope predates device-specific sharing. It remains filled
	// with an opaque copy for schema compatibility; readers use envelopes.
	if _, err := tx.ExecContext(ctx, `INSERT INTO shares (id,node_id,owner_user_id,target_user_id,permission,key_envelope,key_version,created_at,created_by)
		VALUES (?,?,?,?,?,?,?, ?,?)`, share.ID, share.NodeID, share.OwnerUserID, share.TargetUserID, share.Permission, in.Envelopes[0].Ciphertext, in.Envelopes[0].KeyVersion, share.CreatedAt.Format(time.RFC3339Nano), in.OwnerUserID); err != nil {
		if isUniqueConstraint(err) {
			return Share{}, ErrAlreadyShared
		}
		return Share{}, fmt.Errorf("create folder share: %w", err)
	}
	if err := insertEnvelopes(ctx, tx, share.ID, in.Envelopes, share.CreatedAt); err != nil {
		return Share{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO processed_operations (operation_id,user_id,device_id,operation_type,result_code,result_payload,created_at,expires_at)
		VALUES (?,?,?,'SHARE_CREATE','OK',?,?,?)`, in.OperationID, in.OwnerUserID, in.OwnerDeviceID, []byte(share.ID), share.CreatedAt.Format(time.RFC3339Nano), share.CreatedAt.Add(30*24*time.Hour).Format(time.RFC3339Nano)); err != nil {
		return Share{}, err
	}
	if err := tx.Commit(); err != nil {
		return Share{}, err
	}
	return s.GetOutgoing(ctx, in.OwnerUserID, share.ID)
}

// AddEnvelopes delivers folder keys to recipient devices of an existing
// share: a device the recipient approved after the share was created, or
// every remaining device after the owner rotated the folder key. An
// envelope already stored for the same device and key version is kept.
func (s *Service) AddEnvelopes(ctx context.Context, ownerUserID, ownerDeviceID, shareID string, envelopes []DeviceEnvelope) (Share, error) {
	if !access.ValidUUID(ownerUserID) || !access.ValidUUID(ownerDeviceID) || !access.ValidUUID(shareID) {
		return Share{}, apierror.NewValidation("owner, device, and share IDs must be valid UUIDs")
	}
	if len(envelopes) == 0 || len(envelopes) > maxEnvelopesPerRequest {
		return Share{}, apierror.NewValidation(fmt.Sprintf("send 1 to %d device envelopes", maxEnvelopesPerRequest))
	}
	if err := validateEnvelopes(envelopes); err != nil {
		return Share{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Share{}, err
	}
	defer tx.Rollback()
	if err := requireActiveDevice(ctx, tx, ownerUserID, ownerDeviceID); err != nil {
		return Share{}, err
	}
	var nodeID, targetUserID string
	if err := tx.QueryRowContext(ctx, "SELECT node_id,target_user_id FROM shares WHERE id=? AND owner_user_id=? AND revoked_at IS NULL", shareID, ownerUserID).Scan(&nodeID, &targetUserID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Share{}, ErrNotFound
		}
		return Share{}, err
	}
	if err := requireEnvelopeTargets(ctx, tx, nodeID, targetUserID, envelopes); err != nil {
		return Share{}, err
	}
	if err := insertEnvelopes(ctx, tx, shareID, envelopes, s.now().UTC()); err != nil {
		return Share{}, err
	}
	if err := tx.Commit(); err != nil {
		return Share{}, err
	}
	return s.GetOutgoing(ctx, ownerUserID, shareID)
}

// ListIncoming returns the active shares addressed to userID with the
// envelopes of deviceID. A share this device has no envelope for yet is
// still listed, so the recipient can see it is waiting for the owner.
func (s *Service) ListIncoming(ctx context.Context, userID, deviceID string) ([]Share, error) {
	if !access.ValidUUID(userID) || !access.ValidUUID(deviceID) {
		return nil, apierror.NewValidation("user and device IDs must be valid UUIDs")
	}
	rows, err := s.db.QueryContext(ctx, shareSelect+`
		LEFT JOIN share_device_envelopes e ON e.share_id=sh.id AND e.target_device_id=? AND e.revoked_at IS NULL
		JOIN nodes n ON n.id=sh.node_id
		WHERE sh.target_user_id=? AND sh.revoked_at IS NULL AND n.deleted_at IS NULL ORDER BY sh.created_at,sh.id,e.key_version`, deviceID, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanShares(rows)
}

func (s *Service) GetOutgoing(ctx context.Context, ownerUserID, shareID string) (Share, error) {
	if !access.ValidUUID(ownerUserID) || !access.ValidUUID(shareID) {
		return Share{}, apierror.NewValidation("owner and share IDs must be valid UUIDs")
	}
	rows, err := s.db.QueryContext(ctx, shareSelect+`
		LEFT JOIN share_device_envelopes e ON e.share_id=sh.id AND e.revoked_at IS NULL
		WHERE sh.id=? AND sh.owner_user_id=? AND sh.revoked_at IS NULL ORDER BY e.key_version,e.created_at`, shareID, ownerUserID)
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
	if !access.ValidUUID(ownerUserID) {
		return nil, apierror.NewValidation("owner ID must be a valid UUID")
	}
	rows, err := s.db.QueryContext(ctx, shareSelect+`
		LEFT JOIN share_device_envelopes e ON e.share_id=sh.id AND e.revoked_at IS NULL
		WHERE sh.owner_user_id=? AND sh.revoked_at IS NULL ORDER BY sh.created_at,sh.id,e.key_version,e.created_at`, ownerUserID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanShares(rows)
}

// Revoke immediately ends the recipient's server access to the folder. It
// cannot take back keys the recipient already decrypted; the owner's
// client therefore rotates the folder key right afterwards (spec §28.3).
func (s *Service) Revoke(ctx context.Context, ownerUserID, ownerDeviceID, shareID string) error {
	if !access.ValidUUID(ownerUserID) || !access.ValidUUID(ownerDeviceID) || !access.ValidUUID(shareID) {
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

const shareSelect = `SELECT sh.id,sh.node_id,sh.owner_user_id,sh.target_user_id,sh.permission,sh.created_at,
		owner.username,target.username,e.target_device_id,e.key_version,e.envelope_ciphertext,e.owner_identity_public_key,e.owner_signature
		FROM shares sh JOIN users owner ON owner.id=sh.owner_user_id JOIN users target ON target.id=sh.target_user_id`

func scanShares(rows *sql.Rows) ([]Share, error) {
	byID := map[string]*Share{}
	var order []string
	for rows.Next() {
		var share Share
		var created string
		var deviceID sql.NullString
		var keyVersion sql.NullInt64
		var ciphertext, identityKey, signature []byte
		if err := rows.Scan(&share.ID, &share.NodeID, &share.OwnerUserID, &share.TargetUserID, &share.Permission, &created,
			&share.OwnerUsername, &share.TargetUsername, &deviceID, &keyVersion, &ciphertext, &identityKey, &signature); err != nil {
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
		if deviceID.Valid {
			current.Envelopes = append(current.Envelopes, DeviceEnvelope{
				TargetDeviceID: deviceID.String, KeyVersion: int(keyVersion.Int64), Ciphertext: ciphertext,
				OwnerIdentityPublicKey: identityKey, OwnerSignature: signature,
			})
		}
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

func validateEnvelopes(envelopes []DeviceEnvelope) error {
	seen := map[string]bool{}
	for _, envelope := range envelopes {
		key := fmt.Sprintf("%s/%d", envelope.TargetDeviceID, envelope.KeyVersion)
		if !access.ValidUUID(envelope.TargetDeviceID) || envelope.KeyVersion < 1 || len(envelope.Ciphertext) == 0 || len(envelope.Ciphertext) > maxEnvelopeSize || seen[key] {
			return apierror.NewValidation("share device envelopes must be unique, versioned, and reasonably sized")
		}
		if len(envelope.OwnerIdentityPublicKey) != ownerIdentityKeyLength || len(envelope.OwnerSignature) != ownerSignatureLength {
			return apierror.NewValidation("share device envelopes must carry the owner's account-identity signature")
		}
		seen[key] = true
	}
	return nil
}

// requireEnvelopeTargets checks that every envelope is addressed to an
// active device of the recipient and to an existing version of the
// folder's key.
func requireEnvelopeTargets(ctx context.Context, tx *sql.Tx, folderID, targetUserID string, envelopes []DeviceEnvelope) error {
	for _, envelope := range envelopes {
		if err := requireActiveDevice(ctx, tx, targetUserID, envelope.TargetDeviceID); err != nil {
			return ErrTargetNotFound
		}
		var exists bool
		if err := tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM folder_keys WHERE folder_id=? AND key_version=?)", folderID, envelope.KeyVersion).Scan(&exists); err != nil {
			return err
		}
		if !exists {
			return apierror.NewValidation("a share envelope refers to a folder key version that does not exist")
		}
	}
	return nil
}

func insertEnvelopes(ctx context.Context, tx *sql.Tx, shareID string, envelopes []DeviceEnvelope, now time.Time) error {
	for _, envelope := range envelopes {
		if _, err := tx.ExecContext(ctx, `INSERT INTO share_device_envelopes
			(id,share_id,target_device_id,key_version,envelope_ciphertext,owner_identity_public_key,owner_signature,created_at)
			VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(share_id,target_device_id,key_version) DO NOTHING`,
			uuid.NewString(), shareID, envelope.TargetDeviceID, envelope.KeyVersion, envelope.Ciphertext,
			envelope.OwnerIdentityPublicKey, envelope.OwnerSignature, now.Format(time.RFC3339Nano)); err != nil {
			return fmt.Errorf("create recipient envelope: %w", err)
		}
	}
	return nil
}

// requireOwnedFolder accepts only a non-deleted directory of ownerUserID.
func requireOwnedFolder(ctx context.Context, tx *sql.Tx, ownerUserID, folderID string) error {
	var nodeType string
	var deleted sql.NullString
	if err := tx.QueryRowContext(ctx, "SELECT node_type,deleted_at FROM nodes WHERE id=? AND owner_id=?", folderID, ownerUserID).Scan(&nodeType, &deleted); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrForbidden
		}
		return err
	}
	if nodeType != "DIRECTORY" || deleted.Valid {
		return apierror.NewValidation("only a non-deleted folder can be shared")
	}
	return nil
}

// forbidNestedScope refuses a first folder key when an ancestor or a
// descendant of the folder already is a shared folder.
func forbidNestedScope(ctx context.Context, tx *sql.Tx, folderID string) error {
	var parentID sql.NullString
	if err := tx.QueryRowContext(ctx, "SELECT parent_id FROM nodes WHERE id=?", folderID).Scan(&parentID); err != nil {
		return err
	}
	if parentID.Valid {
		outer, err := access.NearestKeyedFolder(ctx, tx, parentID.String)
		if err != nil {
			return err
		}
		if outer != "" {
			return access.ErrNestedSharedFolder
		}
	}
	nested, err := access.SubtreeHasKeyedFolder(ctx, tx, folderID)
	if err != nil {
		return err
	}
	if nested {
		return access.ErrNestedSharedFolder
	}
	return nil
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
	if userID != in.OwnerUserID || deviceID != in.OwnerDeviceID || operationType != "SHARE_CREATE" || !access.ValidUUID(string(payload)) {
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

func isUniqueConstraint(err error) bool {
	return strings.Contains(strings.ToLower(err.Error()), "unique constraint")
}
