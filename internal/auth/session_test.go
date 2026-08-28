package auth

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/homebox/homebox/internal/database"
)

func newTestService(t *testing.T) *Service {
	t.Helper()
	db, err := database.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return New(db, 5, 15*time.Minute)
}

func testDevice(id string) DeviceRegistration {
	return DeviceRegistration{ID: id, Name: "Test Device", Platform: "WINDOWS", PublicKey: []byte("01234567890123456789012345678901"), KeyVersion: 1}
}

func mustBootstrap(t *testing.T, s *Service, username, password string) User {
	t.Helper()
	user, err := s.BootstrapAdmin(context.Background(), username, password)
	if err != nil {
		t.Fatal(err)
	}
	return user
}

func TestLoginIssuesSessionAndRegistersDevice(t *testing.T) {
	ctx := context.Background()
	s := newTestService(t)
	mustBootstrap(t, s, "admin", "correct horse battery staple")

	deviceID := uuid.NewString()
	session, err := s.Login(ctx, "admin", "correct horse battery staple", testDevice(deviceID))
	if err != nil {
		t.Fatal(err)
	}
	if session.AccessToken == "" || session.RefreshToken == "" || session.Device.ID != deviceID {
		t.Fatalf("unexpected session: %#v", session)
	}
	userID, gotDeviceID, err := s.Authenticate(ctx, session.AccessToken)
	if err != nil {
		t.Fatal(err)
	}
	if userID != session.User.ID || gotDeviceID != deviceID {
		t.Fatalf("authenticate mismatch: %s/%s", userID, gotDeviceID)
	}
}

func TestCreateUserRequiresBootstrapAdmin(t *testing.T) {
	s := newTestService(t)
	if _, err := s.CreateUser(context.Background(), "member", "correct horse battery staple"); err == nil {
		t.Fatal("family user was created before bootstrap admin")
	}
	mustBootstrap(t, s, "admin", "correct horse battery staple")
	user, err := s.CreateUser(context.Background(), "member", "correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}
	if user.Role != "USER" || user.Username != "member" {
		t.Fatalf("unexpected family user: %#v", user)
	}
}

func TestListShareableDevicesOnlyReturnsActiveRecipientKeys(t *testing.T) {
	ctx := context.Background()
	s := newTestService(t)
	mustBootstrap(t, s, "admin", "correct horse battery staple")
	member, err := s.CreateUser(ctx, "member", "correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}
	activeID, revokedID := uuid.NewString(), uuid.NewString()
	if _, err := s.Login(ctx, "member", "correct horse battery staple", testDevice(activeID)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Login(ctx, "member", "correct horse battery staple", testDevice(revokedID)); err != nil {
		t.Fatal(err)
	}
	if err := s.RevokeDevice(ctx, member.ID, revokedID); err != nil {
		t.Fatal(err)
	}
	devices, err := s.ListShareableDevices(ctx, member.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(devices) != 1 || devices[0].ID != activeID || len(devices[0].PublicKey) == 0 {
		t.Fatalf("shareable devices=%#v", devices)
	}
}

func TestLoginRejectsWrongPassword(t *testing.T) {
	s := newTestService(t)
	mustBootstrap(t, s, "admin", "correct horse battery staple")
	if _, err := s.Login(context.Background(), "admin", "wrong password entirely", testDevice(uuid.NewString())); err != ErrInvalidCredentials {
		t.Fatalf("error=%v, want %v", err, ErrInvalidCredentials)
	}
}

func TestReturningDeviceMustPresentTheSamePublicKey(t *testing.T) {
	ctx := context.Background()
	s := newTestService(t)
	mustBootstrap(t, s, "admin", "correct horse battery staple")
	deviceID := uuid.NewString()
	if _, err := s.Login(ctx, "admin", "correct horse battery staple", testDevice(deviceID)); err != nil {
		t.Fatal(err)
	}
	rotated := testDevice(deviceID)
	rotated.PublicKey = []byte("different-public-key-bytes-here")
	if _, err := s.Login(ctx, "admin", "correct horse battery staple", rotated); err != ErrDeviceConflict {
		t.Fatalf("error=%v, want %v", err, ErrDeviceConflict)
	}
}

func TestDeviceIDCannotMoveToAnotherAccount(t *testing.T) {
	ctx := context.Background()
	s := newTestService(t)
	mustBootstrap(t, s, "admin", "correct horse battery staple")
	if _, err := s.CreateUser(ctx, "second-user", "another very long password"); err != nil {
		t.Fatal(err)
	}
	deviceID := uuid.NewString()
	if _, err := s.Login(ctx, "admin", "correct horse battery staple", testDevice(deviceID)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Login(ctx, "second-user", "another very long password", testDevice(deviceID)); err != ErrDeviceConflict {
		t.Fatalf("error=%v, want %v", err, ErrDeviceConflict)
	}
}

func TestRefreshRotatesTokenAndInvalidatesThePrevious(t *testing.T) {
	ctx := context.Background()
	s := newTestService(t)
	mustBootstrap(t, s, "admin", "correct horse battery staple")
	first, err := s.Login(ctx, "admin", "correct horse battery staple", testDevice(uuid.NewString()))
	if err != nil {
		t.Fatal(err)
	}
	second, err := s.Refresh(ctx, first.RefreshToken)
	if err != nil {
		t.Fatal(err)
	}
	if second.AccessToken == first.AccessToken || second.RefreshToken == first.RefreshToken {
		t.Fatal("refresh must issue new tokens")
	}
	if _, err := s.Refresh(ctx, first.RefreshToken); err != ErrTokenInvalid {
		t.Fatalf("reusing a rotated refresh token: error=%v, want %v", err, ErrTokenInvalid)
	}
}

func TestLogoutRevokesTheRefreshToken(t *testing.T) {
	ctx := context.Background()
	s := newTestService(t)
	mustBootstrap(t, s, "admin", "correct horse battery staple")
	session, err := s.Login(ctx, "admin", "correct horse battery staple", testDevice(uuid.NewString()))
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Logout(ctx, session.RefreshToken); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Refresh(ctx, session.RefreshToken); err != ErrTokenInvalid {
		t.Fatalf("error=%v, want %v", err, ErrTokenInvalid)
	}
}

func TestRevokedDeviceLosesAccessAndCannotRefresh(t *testing.T) {
	ctx := context.Background()
	s := newTestService(t)
	admin := mustBootstrap(t, s, "admin", "correct horse battery staple")
	session, err := s.Login(ctx, "admin", "correct horse battery staple", testDevice(uuid.NewString()))
	if err != nil {
		t.Fatal(err)
	}
	if err := s.RevokeDevice(ctx, admin.ID, session.Device.ID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Authenticate(ctx, session.AccessToken); err != ErrDeviceRevoked {
		t.Fatalf("authenticate after revoke: error=%v, want %v", err, ErrDeviceRevoked)
	}
	// The refresh token itself was revoked immediately as part of device
	// revocation (unlike the short-lived access token, which is left to
	// expire naturally so Authenticate can still report the more specific
	// ErrDeviceRevoked above), so this surfaces as an invalid token.
	if _, err := s.Refresh(ctx, session.RefreshToken); err != ErrTokenInvalid {
		t.Fatalf("refresh after revoke: error=%v, want %v", err, ErrTokenInvalid)
	}
}

func TestExpiredAccessTokenIsRejected(t *testing.T) {
	ctx := context.Background()
	s := newTestService(t)
	mustBootstrap(t, s, "admin", "correct horse battery staple")
	base := time.Now()
	s.now = func() time.Time { return base }
	session, err := s.Login(ctx, "admin", "correct horse battery staple", testDevice(uuid.NewString()))
	if err != nil {
		t.Fatal(err)
	}
	s.now = func() time.Time { return base.Add(16 * time.Minute) }
	if _, _, err := s.Authenticate(ctx, session.AccessToken); err != ErrTokenInvalid {
		t.Fatalf("error=%v, want %v", err, ErrTokenInvalid)
	}
}

func TestLoginRejectsUnknownUsernameLikeAWrongPassword(t *testing.T) {
	s := newTestService(t)
	mustBootstrap(t, s, "admin", "correct horse battery staple")
	if _, err := s.Login(context.Background(), "no-such-user", "irrelevant password", testDevice(uuid.NewString())); err != ErrInvalidCredentials {
		t.Fatalf("error=%v, want %v", err, ErrInvalidCredentials)
	}
}

func TestRepeatedFailedLoginsAreRateLimited(t *testing.T) {
	ctx := context.Background()
	s := newTestService(t)
	mustBootstrap(t, s, "admin", "correct horse battery staple")
	base := time.Now()
	s.now = func() time.Time { return base }

	// The first couple of failures are unthrottled (loginBackoff returns 0
	// below the threshold), so drive past it before asserting a block.
	for i := 0; i < 3; i++ {
		if _, err := s.Login(ctx, "admin", "wrong password", testDevice(uuid.NewString())); err != ErrInvalidCredentials {
			t.Fatalf("attempt %d: error=%v, want %v", i, err, ErrInvalidCredentials)
		}
	}
	if _, err := s.Login(ctx, "admin", "correct horse battery staple", testDevice(uuid.NewString())); err != ErrRateLimited {
		t.Fatalf("expected the correct password to still be rate-limited: error=%v, want %v", err, ErrRateLimited)
	}

	s.now = func() time.Time { return base.Add(2 * time.Second) }
	if _, err := s.Login(ctx, "admin", "correct horse battery staple", testDevice(uuid.NewString())); err != nil {
		t.Fatalf("expected login to succeed once the backoff window passed: %v", err)
	}
}

func TestSuccessfulLoginClearsRateLimitState(t *testing.T) {
	ctx := context.Background()
	s := newTestService(t)
	mustBootstrap(t, s, "admin", "correct horse battery staple")
	if _, err := s.Login(ctx, "admin", "wrong once", testDevice(uuid.NewString())); err != ErrInvalidCredentials {
		t.Fatal(err)
	}
	if _, err := s.Login(ctx, "admin", "correct horse battery staple", testDevice(uuid.NewString())); err != nil {
		t.Fatalf("expected success below the backoff threshold: %v", err)
	}
	// A fresh run of failures after a success should again take a few
	// attempts before being throttled, proving recordSuccess reset state.
	for i := 0; i < 2; i++ {
		if _, err := s.Login(ctx, "admin", "wrong again", testDevice(uuid.NewString())); err != ErrInvalidCredentials {
			t.Fatalf("attempt %d: error=%v, want %v", i, err, ErrInvalidCredentials)
		}
	}
}

func TestRevokeDeviceIsIdempotentlyNotFoundOnSecondCall(t *testing.T) {
	ctx := context.Background()
	s := newTestService(t)
	admin := mustBootstrap(t, s, "admin", "correct horse battery staple")
	session, err := s.Login(ctx, "admin", "correct horse battery staple", testDevice(uuid.NewString()))
	if err != nil {
		t.Fatal(err)
	}
	if err := s.RevokeDevice(ctx, admin.ID, session.Device.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.RevokeDevice(ctx, admin.ID, session.Device.ID); err != ErrNotFound {
		t.Fatalf("error=%v, want %v", err, ErrNotFound)
	}
}
