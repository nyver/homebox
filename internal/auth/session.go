package auth

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"errors"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/homebox/homebox/internal/apierror"
)

// refreshTokenTTL is not operator-configurable: it only bounds how long a
// device can stay signed in without the user re-entering a password, not
// the E2EE trust boundary, so a fixed generous value keeps config simple.
const refreshTokenTTL = 30 * 24 * time.Hour

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
}

// Login verifies the account password, registers or re-validates the
// presented device, and issues a fresh access/refresh token pair. Server
// login only proves account identity; it never grants E2EE vault access
// (see ADR-012) — callers must not treat a successful Session as unlocking
// file content.
func (s *Service) Login(ctx context.Context, username, password string, device DeviceRegistration) (Session, error) {
	_, normalized, err := normalizeUsername(username)
	if err != nil {
		return Session{}, ErrInvalidCredentials
	}
	if err := validateDeviceRegistration(device); err != nil {
		return Session{}, err
	}
	now := s.now().UTC()
	if !s.loginLimiter.allow(normalized, now) {
		return Session{}, ErrRateLimited
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Session{}, err
	}
	defer tx.Rollback()

	var user User
	var status, passwordHash string
	err = tx.QueryRowContext(ctx, "SELECT id, username, role, status, password_hash FROM users WHERE username_norm = ?",
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
	passwordValid := VerifyPassword(passwordHash, password)
	if !userFound || !passwordValid {
		s.loginLimiter.recordFailure(normalized, now)
		return Session{}, ErrInvalidCredentials
	}
	if status != "ACTIVE" {
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
	return session, nil
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

	var tokenID, userID, deviceID, expiresAt string
	var revokedAt sql.NullString
	err = tx.QueryRowContext(ctx, "SELECT id, user_id, device_id, expires_at, revoked_at FROM refresh_tokens WHERE token_hash = ?", hash[:]).
		Scan(&tokenID, &userID, &deviceID, &expiresAt, &revokedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Session{}, ErrTokenInvalid
	}
	if err != nil {
		return Session{}, err
	}
	if revokedAt.Valid {
		return Session{}, ErrTokenInvalid
	}
	now := s.now().UTC()
	if expires, err := time.Parse(time.RFC3339Nano, expiresAt); err != nil || !now.Before(expires) {
		return Session{}, ErrTokenInvalid
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

	if _, err := tx.ExecContext(ctx, "UPDATE refresh_tokens SET revoked_at = ? WHERE id = ?", now.Format(time.RFC3339Nano), tokenID); err != nil {
		return Session{}, err
	}
	session, err := s.issueTokens(ctx, tx, now, user, dev)
	if err != nil {
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
	var expiresAt string
	err = s.db.QueryRowContext(ctx, "SELECT user_id, device_id, expires_at FROM access_tokens WHERE token_hash = ?", hash[:]).
		Scan(&userID, &deviceID, &expiresAt)
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
	var status string
	if err := s.db.QueryRowContext(ctx, "SELECT status FROM users WHERE id = ?", userID).Scan(&status); err != nil || status != "ACTIVE" {
		return "", "", ErrTokenInvalid
	}
	var revoked sql.NullString
	if err := s.db.QueryRowContext(ctx, "SELECT revoked_at FROM devices WHERE id = ?", deviceID).Scan(&revoked); err != nil {
		return "", "", ErrTokenInvalid
	}
	if revoked.Valid {
		return "", "", ErrDeviceRevoked
	}
	return userID, deviceID, nil
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
	rows, err := s.db.QueryContext(ctx, `SELECT id,user_id,name,platform,e2ee_public_key,e2ee_key_version,created_at,last_seen_at,revoked_at
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
	row := s.db.QueryRowContext(ctx, `SELECT id,user_id,name,platform,e2ee_public_key,e2ee_key_version,created_at,last_seen_at,revoked_at
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
	var revokedAt sql.NullString
	if err := row.Scan(&d.ID, &d.UserID, &d.Name, &d.Platform, &d.PublicKey, &d.KeyVersion, &createdAt, &lastSeenAt, &revokedAt); err != nil {
		return Device{}, err
	}
	var err error
	if d.CreatedAt, err = time.Parse(time.RFC3339Nano, createdAt); err != nil {
		return Device{}, err
	}
	if d.LastSeenAt, err = time.Parse(time.RFC3339Nano, lastSeenAt); err != nil {
		return Device{}, err
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
	row := tx.QueryRowContext(ctx, `SELECT id,user_id,name,platform,e2ee_public_key,e2ee_key_version,created_at,last_seen_at,revoked_at
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
	accessHash := TokenHash(accessToken)
	refreshHash := TokenHash(refreshToken)
	accessExpires := now.Add(s.accessTokenTTL)
	refreshExpires := now.Add(refreshTokenTTL)

	if _, err := tx.ExecContext(ctx, `INSERT INTO access_tokens (id,user_id,device_id,token_hash,created_at,expires_at) VALUES (?,?,?,?,?,?)`,
		uuid.NewString(), user.ID, device.ID, accessHash[:], now.Format(time.RFC3339Nano), accessExpires.Format(time.RFC3339Nano)); err != nil {
		return Session{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO refresh_tokens (id,user_id,device_id,token_hash,created_at,expires_at) VALUES (?,?,?,?,?,?)`,
		uuid.NewString(), user.ID, device.ID, refreshHash[:], now.Format(time.RFC3339Nano), refreshExpires.Format(time.RFC3339Nano)); err != nil {
		return Session{}, err
	}
	return Session{
		User: user, Device: device,
		AccessToken: accessToken, AccessTokenExpiresAt: accessExpires,
		RefreshToken: refreshToken, RefreshTokenExpiresAt: refreshExpires,
	}, nil
}

func randomToken() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

func validateDeviceRegistration(d DeviceRegistration) error {
	if _, err := uuid.Parse(d.ID); err != nil {
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

// newLoginLimiter builds the per-username login backoff tracker (spec §9.3
// "rate limiting login"). It's process-local, in-memory state: acceptable
// at the product's target scale (≤5 users), and a restart simply resets it
// rather than leaving anyone permanently locked out.
type loginLimiter struct {
	mu      sync.Mutex
	entries map[string]*loginLimiterEntry
}

type loginLimiterEntry struct {
	consecutiveFailures int
	blockedUntil        time.Time
}

func newLoginLimiter() *loginLimiter {
	return &loginLimiter{entries: make(map[string]*loginLimiterEntry)}
}

// allow reports whether a login attempt for username may proceed. It never
// touches the database or Argon2id, so a blocked caller is rejected cheaply.
func (l *loginLimiter) allow(username string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	entry := l.entries[username]
	// !Before rather than After: when the backoff is zero, blockedUntil
	// equals the failure's own timestamp, and the very next attempt (at the
	// same or a later time) must still be allowed.
	return entry == nil || !now.Before(entry.blockedUntil)
}

func (l *loginLimiter) recordFailure(username string, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	entry := l.entries[username]
	if entry == nil {
		entry = &loginLimiterEntry{}
		l.entries[username] = entry
	}
	entry.consecutiveFailures++
	entry.blockedUntil = now.Add(loginBackoff(entry.consecutiveFailures))
}

func (l *loginLimiter) recordSuccess(username string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.entries, username)
}

// loginBackoff grows with consecutive failures: harmless for a genuine typo
// (the first couple of attempts are unthrottled) while making sustained
// password guessing increasingly expensive in wall-clock time on top of
// Argon2id's own per-attempt cost.
func loginBackoff(consecutiveFailures int) time.Duration {
	switch {
	case consecutiveFailures < 3:
		return 0
	case consecutiveFailures < 5:
		return time.Second
	case consecutiveFailures < 8:
		return 10 * time.Second
	default:
		return time.Minute
	}
}
