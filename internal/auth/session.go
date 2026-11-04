package auth

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"errors"
	"log"
	"time"

	"github.com/google/uuid"
	"github.com/homebox/homebox/internal/apierror"
)

// refreshTokenTTL is not operator-configurable: it only bounds how long a
// device can stay signed in without the user re-entering a password, not
// the E2EE trust boundary, so a fixed generous value keeps config simple.
const refreshTokenTTL = 30 * 24 * time.Hour

// refreshRetryGrace is how long a just-rotated refresh token may still be
// presented. It covers a client whose connection dropped after the server
// committed a rotation but before the response arrived; without it that
// client would hold only a revoked token and be forced to log in again.
const refreshRetryGrace = time.Minute

// recordSyncInterval bounds how often a polling device rewrites its
// last_sync_at timestamp.
const recordSyncInterval = time.Minute

var (
	ErrInvalidCredentials = errors.New("invalid username or password")
	ErrAccountDisabled    = errors.New("account is disabled")
	ErrDeviceRevoked      = errors.New("device has been revoked")
	ErrDeviceConflict     = errors.New("device id belongs to a different account or key")
	ErrTokenInvalid       = errors.New("token is invalid, expired, or revoked")
	ErrNotFound           = errors.New("not found")
	ErrRateLimited        = errors.New("too many failed login attempts; try again later")
)

// dummyPasswordHash lets Login run Argon2id verification even when the
// username doesn't exist, so a failed login for an unknown username takes
// about as long as one for a known username with a wrong password. Without
// this, the missing-user path returns immediately after a single indexed
// lookup while the wrong-password path pays for a full Argon2id hash,
// letting an attacker enumerate valid usernames by response time alone.
var dummyPasswordHash = mustHashPassword("timing-normalization-dummy-password-never-used")

func mustHashPassword(password string) string {
	hash, err := HashPassword(password)
	if err != nil {
		// Unreachable in practice: HashPassword only fails if the OS CSPRNG
		// is unavailable, which the process cannot usefully run without.
		panic(err)
	}
	return hash
}

// DeviceRegistration is the wire-level device description a client presents
// at login. The device ID is client-generated so devices created offline
// (or before their first successful login) still have a stable identity.
type DeviceRegistration struct {
	ID         string
	Name       string
	Platform   string // WINDOWS | ANDROID | OTHER
	PublicKey  []byte // opaque E2EE device public key; the server never inspects its structure
	KeyVersion int
}

type Device struct {
	ID         string
	UserID     string
	Name       string
	Platform   string
	PublicKey  []byte
	KeyVersion int
	CreatedAt  time.Time
	LastSeenAt time.Time
	LastSyncAt *time.Time
	RevokedAt  *time.Time
}

// ShareableDevice contains the minimum public information an owner needs to
// construct a recipient-device-specific E2EE envelope. It intentionally has
// no user-facing device name or activity timestamps.
type ShareableDevice struct {
	ID         string
	Platform   string
	PublicKey  []byte
	KeyVersion int
}

type Session struct {
	User                  User
	Device                Device
	AccessToken           string
	AccessTokenExpiresAt  time.Time
	RefreshToken          string
	RefreshTokenExpiresAt time.Time

	refreshTokenID string
}

// Login verifies the account password, registers or re-validates the
// presented device, and issues a fresh access/refresh token pair. Server
// login only proves account identity; it never grants E2EE vault access
// (see ADR-012) — callers must not treat a successful Session as unlocking
// file content.
//
// clientAddr identifies the caller's network address for spray throttling
// across usernames; an empty value disables only that address limit.
func (s *Service) Login(ctx context.Context, clientAddr, username, password string, device DeviceRegistration) (Session, error) {
	_, normalized, err := normalizeUsername(username)
	if err != nil {
		return Session{}, ErrInvalidCredentials
	}
	if err := validateDeviceRegistration(device); err != nil {
		return Session{}, err
	}
	now := s.now().UTC()
	if !s.addressLimiter.begin(clientAddr, now) {
		return Session{}, ErrRateLimited
	}
	defer s.addressLimiter.end(clientAddr)
	if !s.loginLimiter.begin(normalized, now) {
		return Session{}, ErrRateLimited
	}
	defer s.loginLimiter.end(normalized)

	// The password is verified before any transaction is opened: Argon2id
	// takes a noticeable fraction of a second and 64 MiB, and holding a
	// write transaction across it would stall every other writer.
	var user User
	var status, passwordHash string
	err = s.db.QueryRowContext(ctx, "SELECT id, username, role, status, password_hash FROM users WHERE username_norm = ?",
		normalized).Scan(&user.ID, &user.Username, &user.Role, &status, &passwordHash)
	userFound := true
	switch {
	case errors.Is(err, sql.ErrNoRows):
		userFound = false
		passwordHash = dummyPasswordHash
	case err != nil:
		return Session{}, err
	}
	// Always run Argon2id, even for a nonexistent user, so response time
	// doesn't reveal which usernames exist (see dummyPasswordHash).
	passwordValid, err := s.verifyPassword(ctx, passwordHash, password)
	if err != nil {
		return Session{}, err
	}
	if !userFound || !passwordValid {
		s.loginLimiter.recordFailure(normalized, now)
		s.addressLimiter.recordFailure(clientAddr, now)
		return Session{}, ErrInvalidCredentials
	}
	if status != "ACTIVE" {
		return Session{}, ErrAccountDisabled
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Session{}, err
	}
	defer tx.Rollback()
	// Re-check inside the write transaction: the account may have been
	// disabled or its password changed while Argon2id was running.
	var currentStatus, currentHash string
	if err := tx.QueryRowContext(ctx, "SELECT status, password_hash FROM users WHERE id = ?", user.ID).Scan(&currentStatus, &currentHash); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Session{}, ErrInvalidCredentials
		}
		return Session{}, err
	}
	if currentHash != passwordHash {
		return Session{}, ErrInvalidCredentials
	}
	if currentStatus != "ACTIVE" {
		return Session{}, ErrAccountDisabled
	}

	dev, err := s.upsertDevice(ctx, tx, now, user.ID, device)
	if err != nil {
		return Session{}, err
	}
	session, err := s.issueTokens(ctx, tx, now, user, dev)
	if err != nil {
		return Session{}, err
	}
	if err := tx.Commit(); err != nil {
		return Session{}, err
	}
	s.loginLimiter.recordSuccess(normalized)
	s.addressLimiter.recordSuccess(clientAddr)
	return session, nil
}

// verifyPassword runs Argon2id under a small concurrency cap so a burst of
// login requests cannot multiply its 64 MiB working set into memory
// exhaustion or starve the CPU for every other request.
func (s *Service) verifyPassword(ctx context.Context, encoded, password string) (bool, error) {
	select {
	case s.passwordSlots <- struct{}{}:
	case <-ctx.Done():
		return false, ctx.Err()
	}
	defer func() { <-s.passwordSlots }()
	return VerifyPassword(encoded, password), nil
}

// Refresh rotates a refresh token: the presented token is revoked and a new
// access/refresh pair is issued, limiting how long a leaked refresh token
// stays useful.
func (s *Service) Refresh(ctx context.Context, refreshToken string) (Session, error) {
	if refreshToken == "" {
		return Session{}, ErrTokenInvalid
	}
	hash := TokenHash(refreshToken)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Session{}, err
	}
	defer tx.Rollback()

	var userID, deviceID, expiresAt string
	var revokedAt, rotatedTo sql.NullString
	err = tx.QueryRowContext(ctx, "SELECT user_id, device_id, expires_at, revoked_at, rotated_to FROM refresh_tokens WHERE token_hash = ?", hash[:]).
		Scan(&userID, &deviceID, &expiresAt, &revokedAt, &rotatedTo)
	if errors.Is(err, sql.ErrNoRows) {
		return Session{}, ErrTokenInvalid
	}
	if err != nil {
		return Session{}, err
	}
	now := s.now().UTC()
	if expires, err := time.Parse(time.RFC3339Nano, expiresAt); err != nil || !now.Before(expires) {
		return Session{}, ErrTokenInvalid
	}
	if revokedAt.Valid {
		// Logout and device revocation never set rotated_to: such a token
		// is simply dead.
		if !rotatedTo.Valid {
			return Session{}, ErrTokenInvalid
		}
		revoked, err := time.Parse(time.RFC3339Nano, revokedAt.String)
		if err != nil {
			return Session{}, ErrTokenInvalid
		}
		if now.Sub(revoked) > refreshRetryGrace {
			// A rotated token presented long after its rotation means two
			// parties hold this device's refresh chain: end every session
			// of the device so the legitimate user re-authenticates.
			if err := revokeDeviceTokens(ctx, tx, deviceID, now); err != nil {
				return Session{}, err
			}
			if err := tx.Commit(); err != nil {
				return Session{}, err
			}
			log.Printf("auth: rotated refresh token reused for device %s; all of its sessions were revoked", deviceID)
			return Session{}, ErrTokenInvalid
		}
		// Within the grace period this is a client retrying after it lost
		// the previous refresh response; reissue below and retire the
		// successor it never received.
	}

	var user User
	var status string
	if err := tx.QueryRowContext(ctx, "SELECT id, username, role, status FROM users WHERE id = ?", userID).
		Scan(&user.ID, &user.Username, &user.Role, &status); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Session{}, ErrTokenInvalid
		}
		return Session{}, err
	}
	if status != "ACTIVE" {
		return Session{}, ErrAccountDisabled
	}
	dev, err := s.loadDevice(ctx, tx, deviceID, userID)
	if err != nil {
		return Session{}, err
	}
	if dev.RevokedAt != nil {
		return Session{}, ErrDeviceRevoked
	}

	session, err := s.issueTokens(ctx, tx, now, user, dev)
	if err != nil {
		return Session{}, err
	}
	// Retires the presented token and, on a grace-period retry, the
	// successor issued by the lost response. A device holds one session.
	if _, err := tx.ExecContext(ctx, "UPDATE refresh_tokens SET revoked_at = ?, rotated_to = ? WHERE device_id = ? AND revoked_at IS NULL AND id != ?",
		now.Format(time.RFC3339Nano), session.refreshTokenID, deviceID, session.refreshTokenID); err != nil {
		return Session{}, err
	}
	if err := tx.Commit(); err != nil {
		return Session{}, err
	}
	return session, nil
}

// Logout revokes a single refresh token. It is intentionally not an error to
// log out with an already-revoked or unknown token.
func (s *Service) Logout(ctx context.Context, refreshToken string) error {
	if refreshToken == "" {
		return nil
	}
	hash := TokenHash(refreshToken)
	_, err := s.db.ExecContext(ctx, "UPDATE refresh_tokens SET revoked_at = ? WHERE token_hash = ? AND revoked_at IS NULL",
		s.now().UTC().Format(time.RFC3339Nano), hash[:])
	return err
}

// Authenticate validates a bearer access token and returns the identity it
// was issued to. It re-checks account/device status on every call so a
// revoke takes effect immediately rather than waiting for token expiry.
func (s *Service) Authenticate(ctx context.Context, accessToken string) (userID, deviceID string, err error) {
	if accessToken == "" {
		return "", "", ErrTokenInvalid
	}
	hash := TokenHash(accessToken)
	var expiresAt, status string
	var revoked sql.NullString
	err = s.db.QueryRowContext(ctx, `SELECT a.user_id, a.device_id, a.expires_at, u.status, d.revoked_at
		FROM access_tokens a JOIN users u ON u.id = a.user_id JOIN devices d ON d.id = a.device_id
		WHERE a.token_hash = ?`, hash[:]).Scan(&userID, &deviceID, &expiresAt, &status, &revoked)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", ErrTokenInvalid
	}
	if err != nil {
		return "", "", err
	}
	expires, err := time.Parse(time.RFC3339Nano, expiresAt)
	if err != nil || !s.now().UTC().Before(expires) {
		return "", "", ErrTokenInvalid
	}
	if status != "ACTIVE" {
		return "", "", ErrTokenInvalid
	}
	if revoked.Valid {
		return "", "", ErrDeviceRevoked
	}
	return userID, deviceID, nil
}

// RecordSync marks a device only after it has successfully read the account's
// sync feed. This deliberately differs from LastSeenAt, which means merely
// that the device logged in or refreshed its session.
func (s *Service) RecordSync(ctx context.Context, userID, deviceID string) error {
	now := s.now().UTC()
	var lastSyncAt sql.NullString
	err := s.db.QueryRowContext(ctx, "SELECT last_sync_at FROM devices WHERE id = ? AND user_id = ? AND revoked_at IS NULL",
		deviceID, userID).Scan(&lastSyncAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	// Clients poll the feed often; the Settings device list only needs
	// minute precision, so skip the write for a recent timestamp.
	if lastSyncAt.Valid {
		if last, err := time.Parse(time.RFC3339Nano, lastSyncAt.String); err == nil {
			if elapsed := now.Sub(last); elapsed >= 0 && elapsed < recordSyncInterval {
				return nil
			}
		}
	}
	result, err := s.db.ExecContext(ctx, `UPDATE devices SET last_sync_at = ?
		WHERE id = ? AND user_id = ? AND revoked_at IS NULL`, now.Format(time.RFC3339Nano), deviceID, userID)
	if err != nil {
		return err
	}
	if affected, err := result.RowsAffected(); err != nil {
		return err
	} else if affected != 1 {
		return ErrNotFound
	}
	return nil
}

// RevokeDevice immediately stops a device's tokens and any future
// key-envelope delivery. It does not and cannot retract data already
// decrypted by that device before revocation (see ADR-012/§10.11).
func (s *Service) RevokeDevice(ctx context.Context, userID, deviceID string) error {
	now := s.now().UTC().Format(time.RFC3339Nano)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, "UPDATE devices SET revoked_at = ? WHERE id = ? AND user_id = ? AND revoked_at IS NULL", now, deviceID, userID)
	if err != nil {
		return err
	}
	if affected, err := result.RowsAffected(); err != nil || affected == 0 {
		return ErrNotFound
	}
	if _, err := tx.ExecContext(ctx, "UPDATE refresh_tokens SET revoked_at = ? WHERE device_id = ? AND revoked_at IS NULL", now, deviceID); err != nil {
		return err
	}
	// Existing access tokens are deliberately left in place rather than
	// deleted: Authenticate re-checks devices.revoked_at on every call, so
	// they stop working immediately anyway, and keeping the row lets
	// Authenticate report the more specific ErrDeviceRevoked instead of a
	// generic "token not found".
	return tx.Commit()
}

func (s *Service) ListDevices(ctx context.Context, userID string) ([]Device, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id,user_id,name,platform,e2ee_public_key,e2ee_key_version,created_at,last_seen_at,last_sync_at,revoked_at
		FROM devices WHERE user_id = ? ORDER BY created_at`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var devices []Device
	for rows.Next() {
		d, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		devices = append(devices, d)
	}
	return devices, rows.Err()
}

// ListShareableDevices returns only active recipient device public keys. The
// caller is expected to know the opaque user ID through a deliberate family
// invite; device names and revoked keys are deliberately excluded.
func (s *Service) ListShareableDevices(ctx context.Context, userID string) ([]ShareableDevice, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT d.id,d.platform,d.e2ee_public_key,d.e2ee_key_version
		FROM devices d JOIN users u ON u.id=d.user_id
		WHERE d.user_id=? AND d.revoked_at IS NULL AND u.status='ACTIVE' ORDER BY d.created_at`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var devices []ShareableDevice
	for rows.Next() {
		var d ShareableDevice
		if err := rows.Scan(&d.ID, &d.Platform, &d.PublicKey, &d.KeyVersion); err != nil {
			return nil, err
		}
		devices = append(devices, d)
	}
	return devices, rows.Err()
}

// GetDevice returns a device belonging to userID, or ErrNotFound. Callers
// must separately check the returned Device.RevokedAt if a revoked device
// should be rejected.
func (s *Service) GetDevice(ctx context.Context, userID, deviceID string) (Device, error) {
	row := s.db.QueryRowContext(ctx, `SELECT id,user_id,name,platform,e2ee_public_key,e2ee_key_version,created_at,last_seen_at,last_sync_at,revoked_at
		FROM devices WHERE id = ? AND user_id = ?`, deviceID, userID)
	d, err := scanDevice(row)
	if errors.Is(err, sql.ErrNoRows) {
		return Device{}, ErrNotFound
	}
	return d, err
}

func (s *Service) GetUser(ctx context.Context, id string) (User, error) {
	var u User
	err := s.db.QueryRowContext(ctx, "SELECT id, username, role FROM users WHERE id = ?", id).Scan(&u.ID, &u.Username, &u.Role)
	if errors.Is(err, sql.ErrNoRows) {
		return User{}, ErrNotFound
	}
	return u, err
}

type scanner interface {
	Scan(dest ...any) error
}

func scanDevice(row scanner) (Device, error) {
	var d Device
	var createdAt, lastSeenAt string
	var lastSyncAt, revokedAt sql.NullString
	if err := row.Scan(&d.ID, &d.UserID, &d.Name, &d.Platform, &d.PublicKey, &d.KeyVersion, &createdAt, &lastSeenAt, &lastSyncAt, &revokedAt); err != nil {
		return Device{}, err
	}
	var err error
	if d.CreatedAt, err = time.Parse(time.RFC3339Nano, createdAt); err != nil {
		return Device{}, err
	}
	if d.LastSeenAt, err = time.Parse(time.RFC3339Nano, lastSeenAt); err != nil {
		return Device{}, err
	}
	if lastSyncAt.Valid {
		t, err := time.Parse(time.RFC3339Nano, lastSyncAt.String)
		if err != nil {
			return Device{}, err
		}
		d.LastSyncAt = &t
	}
	if revokedAt.Valid {
		t, err := time.Parse(time.RFC3339Nano, revokedAt.String)
		if err != nil {
			return Device{}, err
		}
		d.RevokedAt = &t
	}
	return d, nil
}

func (s *Service) loadDevice(ctx context.Context, tx *sql.Tx, deviceID, userID string) (Device, error) {
	row := tx.QueryRowContext(ctx, `SELECT id,user_id,name,platform,e2ee_public_key,e2ee_key_version,created_at,last_seen_at,last_sync_at,revoked_at
		FROM devices WHERE id = ? AND user_id = ?`, deviceID, userID)
	d, err := scanDevice(row)
	if errors.Is(err, sql.ErrNoRows) {
		return Device{}, ErrTokenInvalid
	}
	return d, err
}

// upsertDevice registers a new device or re-validates a returning one. A
// device ID may only ever belong to one account and one public key: a
// mismatch on either is treated as a conflict rather than silently
// re-keying the device, since that would let a stolen password holder
// substitute their own device key onto an already-trusted device identity.
func (s *Service) upsertDevice(ctx context.Context, tx *sql.Tx, now time.Time, userID string, reg DeviceRegistration) (Device, error) {
	existing, err := s.loadDevice(ctx, tx, reg.ID, userID)
	switch {
	case errors.Is(err, ErrTokenInvalid):
		var conflictCount int
		if err := tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM devices WHERE id = ? AND user_id != ?", reg.ID, userID).Scan(&conflictCount); err != nil {
			return Device{}, err
		}
		if conflictCount > 0 {
			return Device{}, ErrDeviceConflict
		}
		d := Device{ID: reg.ID, UserID: userID, Name: reg.Name, Platform: reg.Platform, PublicKey: reg.PublicKey, KeyVersion: reg.KeyVersion, CreatedAt: now, LastSeenAt: now}
		if _, err := tx.ExecContext(ctx, `INSERT INTO devices (id,user_id,name,platform,e2ee_public_key,e2ee_key_version,created_at,last_seen_at)
			VALUES (?,?,?,?,?,?,?,?)`, d.ID, d.UserID, d.Name, d.Platform, d.PublicKey, d.KeyVersion, now.Format(time.RFC3339Nano), now.Format(time.RFC3339Nano)); err != nil {
			return Device{}, err
		}
		return d, nil
	case err != nil:
		return Device{}, err
	}
	if existing.RevokedAt != nil {
		return Device{}, ErrDeviceRevoked
	}
	if !bytes.Equal(existing.PublicKey, reg.PublicKey) || existing.KeyVersion != reg.KeyVersion {
		return Device{}, ErrDeviceConflict
	}
	if _, err := tx.ExecContext(ctx, "UPDATE devices SET name = ?, last_seen_at = ? WHERE id = ?", reg.Name, now.Format(time.RFC3339Nano), existing.ID); err != nil {
		return Device{}, err
	}
	existing.Name = reg.Name
	existing.LastSeenAt = now
	return existing, nil
}

func (s *Service) issueTokens(ctx context.Context, tx *sql.Tx, now time.Time, user User, device Device) (Session, error) {
	accessToken, err := randomToken()
	if err != nil {
		return Session{}, err
	}
	refreshToken, err := randomToken()
	if err != nil {
		return Session{}, err
	}
	refreshTokenID := uuid.NewString()
	accessHash := TokenHash(accessToken)
	refreshHash := TokenHash(refreshToken)
	accessExpires := now.Add(s.accessTokenTTL)
	refreshExpires := now.Add(refreshTokenTTL)

	if _, err := tx.ExecContext(ctx, `INSERT INTO access_tokens (id,user_id,device_id,token_hash,created_at,expires_at) VALUES (?,?,?,?,?,?)`,
		uuid.NewString(), user.ID, device.ID, accessHash[:], now.Format(time.RFC3339Nano), accessExpires.Format(time.RFC3339Nano)); err != nil {
		return Session{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO refresh_tokens (id,user_id,device_id,token_hash,created_at,expires_at) VALUES (?,?,?,?,?,?)`,
		refreshTokenID, user.ID, device.ID, refreshHash[:], now.Format(time.RFC3339Nano), refreshExpires.Format(time.RFC3339Nano)); err != nil {
		return Session{}, err
	}
	return Session{
		User: user, Device: device,
		AccessToken: accessToken, AccessTokenExpiresAt: accessExpires,
		RefreshToken: refreshToken, RefreshTokenExpiresAt: refreshExpires,
		refreshTokenID: refreshTokenID,
	}, nil
}

// revokeDeviceTokens ends every session of a device whose refresh chain is
// suspected to be compromised.
func revokeDeviceTokens(ctx context.Context, tx *sql.Tx, deviceID string, now time.Time) error {
	if _, err := tx.ExecContext(ctx, "UPDATE refresh_tokens SET revoked_at = ? WHERE device_id = ? AND revoked_at IS NULL", now.Format(time.RFC3339Nano), deviceID); err != nil {
		return err
	}
	_, err := tx.ExecContext(ctx, "DELETE FROM access_tokens WHERE device_id = ?", deviceID)
	return err
}

func randomToken() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

func validateDeviceRegistration(d DeviceRegistration) error {
	if parsed, err := uuid.Parse(d.ID); err != nil || parsed.String() != d.ID {
		return apierror.NewValidation("device id must be a valid UUID")
	}
	if len(d.Name) == 0 || len(d.Name) > 128 {
		return apierror.NewValidation("device name must contain 1 to 128 characters")
	}
	if d.Platform != "WINDOWS" && d.Platform != "ANDROID" && d.Platform != "OTHER" {
		return apierror.NewValidation("device platform must be WINDOWS, ANDROID, or OTHER")
	}
	if len(d.PublicKey) == 0 || len(d.PublicKey) > 4096 {
		return apierror.NewValidation("device public key is required")
	}
	if d.KeyVersion < 1 {
		return apierror.NewValidation("device key version must be at least 1")
	}
	return nil
}
