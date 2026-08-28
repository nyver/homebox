package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"golang.org/x/crypto/argon2"
)

const (
	argonTime    uint32 = 3
	argonMemory  uint32 = 64 * 1024
	argonThreads uint8  = 4
	argonKeyLen  uint32 = 32
)

type Service struct {
	db             *sql.DB
	maxUsers       int
	accessTokenTTL time.Duration
	now            func() time.Time
	loginLimiter   *loginLimiter
}

type User struct {
	ID       string
	Username string
	Role     string
}

// New builds the auth service. accessTokenTTL bounds how long an issued
// access token is valid before a client must present its refresh token
// (config: security.application_encryption.session_max_age).
func New(db *sql.DB, maxUsers int, accessTokenTTL time.Duration) *Service {
	return &Service{db: db, maxUsers: maxUsers, accessTokenTTL: accessTokenTTL, now: time.Now, loginLimiter: newLoginLimiter()}
}

func (s *Service) BootstrapAdmin(ctx context.Context, username, password string) (User, error) {
	username, normalized, err := normalizeUsername(username)
	if err != nil {
		return User{}, err
	}
	if err := validatePassword(password); err != nil {
		return User{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return User{}, err
	}
	defer tx.Rollback()
	var count int
	if err := tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM users").Scan(&count); err != nil {
		return User{}, err
	}
	if count != 0 {
		return User{}, errors.New("bootstrap admin is only allowed before the first user exists")
	}
	hash, err := HashPassword(password)
	if err != nil {
		return User{}, err
	}
	user := User{ID: uuid.NewString(), Username: username, Role: "ADMIN"}
	now := s.now().UTC().Format(time.RFC3339Nano)
	if _, err := tx.ExecContext(ctx, `INSERT INTO users (id,username,username_norm,password_hash,role,status,created_at,updated_at)
		VALUES (?,?,?,?, 'ADMIN','ACTIVE',?,?)`, user.ID, username, normalized, hash, now, now); err != nil {
		return User{}, fmt.Errorf("create bootstrap admin: %w", err)
	}
	return user, tx.Commit()
}

func (s *Service) CreateUser(ctx context.Context, username, password string) (User, error) {
	username, normalized, err := normalizeUsername(username)
	if err != nil {
		return User{}, err
	}
	if err := validatePassword(password); err != nil {
		return User{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return User{}, err
	}
	defer tx.Rollback()
	var count int
	if err := tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM users").Scan(&count); err != nil {
		return User{}, err
	}
	var admins int
	if err := tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM users WHERE role='ADMIN' AND status='ACTIVE'").Scan(&admins); err != nil {
		return User{}, err
	}
	if admins == 0 {
		return User{}, errors.New("create an active bootstrap admin before creating family user accounts")
	}
	if count >= s.maxUsers {
		return User{}, fmt.Errorf("user limit of %d reached", s.maxUsers)
	}
	hash, err := HashPassword(password)
	if err != nil {
		return User{}, err
	}
	user := User{ID: uuid.NewString(), Username: username, Role: "USER"}
	now := s.now().UTC().Format(time.RFC3339Nano)
	if _, err := tx.ExecContext(ctx, `INSERT INTO users (id,username,username_norm,password_hash,role,status,created_at,updated_at)
		VALUES (?,?,?,?, 'USER','ACTIVE',?,?)`, user.ID, username, normalized, hash, now, now); err != nil {
		return User{}, fmt.Errorf("create user: %w", err)
	}
	return user, tx.Commit()
}

func HashPassword(password string) (string, error) {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", fmt.Errorf("generate password salt: %w", err)
	}
	hash := argon2.IDKey([]byte(password), salt, argonTime, argonMemory, argonThreads, argonKeyLen)
	return fmt.Sprintf("$argon2id$v=19$m=%d,t=%d,p=%d$%s$%s", argonMemory, argonTime, argonThreads,
		base64.RawStdEncoding.EncodeToString(salt), base64.RawStdEncoding.EncodeToString(hash)), nil
}

func VerifyPassword(encoded, password string) bool {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[1] != "argon2id" || parts[2] != "v=19" {
		return false
	}
	var memory, iterations uint32
	var threads uint8
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &memory, &iterations, &threads); err != nil || memory < 8*1024 || iterations == 0 || threads == 0 {
		return false
	}
	saltEncoded, hashEncoded := parts[4], parts[5]
	salt, err := base64.RawStdEncoding.DecodeString(saltEncoded)
	if err != nil {
		return false
	}
	expected, err := base64.RawStdEncoding.DecodeString(hashEncoded)
	if err != nil || len(expected) != int(argonKeyLen) {
		return false
	}
	actual := argon2.IDKey([]byte(password), salt, iterations, memory, threads, uint32(len(expected)))
	return subtle.ConstantTimeCompare(actual, expected) == 1
}

func TokenHash(token string) [32]byte { return sha256.Sum256([]byte(token)) }

func normalizeUsername(value string) (string, string, error) {
	value = strings.TrimSpace(value)
	if len(value) < 3 || len(value) > 64 {
		return "", "", errors.New("username must contain 3 to 64 characters")
	}
	for _, r := range value {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_' || r == '.') {
			return "", "", errors.New("username may only contain letters, digits, dots, hyphens, and underscores")
		}
	}
	return value, strings.ToLower(value), nil
}

func validatePassword(password string) error {
	if len(password) < 12 || len(password) > 1024 {
		return errors.New("password must contain 12 to 1024 characters")
	}
	return nil
}
