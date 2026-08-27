package provisioning

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/homebox/homebox/internal/database"
)

func TestLatestReturnsTheMostRecentNonRevokedEnvelope(t *testing.T) {
	ctx := context.Background()
	db, err := database.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	s := New(db)
	userID, deviceID := uuid.NewString(), uuid.NewString()
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := db.ExecContext(ctx, `INSERT INTO users (id,username,username_norm,password_hash,role,status,created_at,updated_at)
		VALUES (?,?,?,'hash','USER','ACTIVE',?,?)`, userID, "user", "user", now, now); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `INSERT INTO devices (id,user_id,name,platform,e2ee_public_key,e2ee_key_version,created_at,last_seen_at)
		VALUES (?,?,?,'WINDOWS',?,1,?,?)`, deviceID, userID, "device", []byte("public-key"), now, now); err != nil {
		t.Fatal(err)
	}

	if _, err := s.Latest(ctx, deviceID); err != ErrNotFound {
		t.Fatalf("error=%v, want %v", err, ErrNotFound)
	}

	first, err := s.Upload(ctx, "vault-1", userID, deviceID, 1, []byte("first-envelope"))
	if err != nil {
		t.Fatal(err)
	}
	got, err := s.Latest(ctx, deviceID)
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != first.ID {
		t.Fatalf("got envelope %s, want %s", got.ID, first.ID)
	}

	second, err := s.Upload(ctx, "vault-1", userID, deviceID, 2, []byte("second-envelope"))
	if err != nil {
		t.Fatal(err)
	}
	got, err = s.Latest(ctx, deviceID)
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != second.ID || string(got.Ciphertext) != "second-envelope" {
		t.Fatalf("got envelope %#v, want the second upload", got)
	}
}

func TestUploadRejectsIncompleteInput(t *testing.T) {
	ctx := context.Background()
	db, err := database.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	s := New(db)
	if _, err := s.Upload(ctx, "", uuid.NewString(), uuid.NewString(), 1, []byte("x")); err == nil {
		t.Fatal("expected an error for a missing vault id")
	}
	if _, err := s.Upload(ctx, "vault-1", uuid.NewString(), uuid.NewString(), 0, []byte("x")); err == nil {
		t.Fatal("expected an error for key version 0")
	}
	if _, err := s.Upload(ctx, "vault-1", uuid.NewString(), uuid.NewString(), 1, nil); err == nil {
		t.Fatal("expected an error for empty ciphertext")
	}
}
