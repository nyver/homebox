package sync

import (
	"context"
	"database/sql"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/homebox/homebox/internal/database"
	"github.com/homebox/homebox/internal/nodes"
)

func TestChangesReturnsOnlyTheCallersScopeInOrder(t *testing.T) {
	ctx := context.Background()
	db, err := database.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	userA, deviceA := seedUserAndDevice(t, db)
	userB, deviceB := seedUserAndDevice(t, db)
	nodeSvc := nodes.New(db)

	for i := 0; i < 3; i++ {
		if _, err := nodeSvc.Create(ctx, nodes.CreateInput{ID: uuid.NewString(), OwnerID: userA, DeviceID: deviceA, OperationID: uuid.NewString(),
			NodeType: "DIRECTORY", MetadataCiphertext: []byte("a"), MetadataKeyVersion: 1}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := nodeSvc.Create(ctx, nodes.CreateInput{ID: uuid.NewString(), OwnerID: userB, DeviceID: deviceB, OperationID: uuid.NewString(),
		NodeType: "DIRECTORY", MetadataCiphertext: []byte("b"), MetadataKeyVersion: 1}); err != nil {
		t.Fatal(err)
	}

	syncSvc := New(db, 10, 100)
	page, err := syncSvc.Changes(ctx, userA, 0, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Changes) != 3 {
		t.Fatalf("expected 3 changes for userA, got %d", len(page.Changes))
	}
	for i := 1; i < len(page.Changes); i++ {
		if page.Changes[i].Revision <= page.Changes[i-1].Revision {
			t.Fatalf("changes are not strictly increasing: %#v", page.Changes)
		}
	}
	if page.HasMore {
		t.Fatal("did not expect more pages")
	}
}

func TestChangesPagesAndReportsHasMore(t *testing.T) {
	ctx := context.Background()
	db, err := database.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	userID, deviceID := seedUserAndDevice(t, db)
	nodeSvc := nodes.New(db)
	for i := 0; i < 5; i++ {
		if _, err := nodeSvc.Create(ctx, nodes.CreateInput{ID: uuid.NewString(), OwnerID: userID, DeviceID: deviceID, OperationID: uuid.NewString(),
			NodeType: "DIRECTORY", MetadataCiphertext: []byte("a"), MetadataKeyVersion: 1}); err != nil {
			t.Fatal(err)
		}
	}

	syncSvc := New(db, 10, 100)
	first, err := syncSvc.Changes(ctx, userID, 0, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(first.Changes) != 2 || !first.HasMore {
		t.Fatalf("unexpected first page: %#v", first)
	}
	second, err := syncSvc.Changes(ctx, userID, first.NextAfter, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(second.Changes) != 2 || !second.HasMore {
		t.Fatalf("unexpected second page: %#v", second)
	}
	third, err := syncSvc.Changes(ctx, userID, second.NextAfter, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(third.Changes) != 1 || third.HasMore {
		t.Fatalf("unexpected third page: %#v", third)
	}
}

func TestChangesRejectsNegativeCursor(t *testing.T) {
	db, err := database.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	syncSvc := New(db, 10, 100)
	if _, err := syncSvc.Changes(context.Background(), uuid.NewString(), -1, 10); err != ErrInvalidCursor {
		t.Fatalf("error=%v, want %v", err, ErrInvalidCursor)
	}
}

func TestChangesClampsPageSizeToMax(t *testing.T) {
	ctx := context.Background()
	db, err := database.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	userID, deviceID := seedUserAndDevice(t, db)
	nodeSvc := nodes.New(db)
	for i := 0; i < 5; i++ {
		if _, err := nodeSvc.Create(ctx, nodes.CreateInput{ID: uuid.NewString(), OwnerID: userID, DeviceID: deviceID, OperationID: uuid.NewString(),
			NodeType: "DIRECTORY", MetadataCiphertext: []byte("a"), MetadataKeyVersion: 1}); err != nil {
			t.Fatal(err)
		}
	}
	syncSvc := New(db, 10, 2)
	page, err := syncSvc.Changes(ctx, userID, 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Changes) != 2 || !page.HasMore {
		t.Fatalf("expected page size clamped to 2: %#v", page)
	}
}

func seedUserAndDevice(t *testing.T, db *sql.DB) (string, string) {
	t.Helper()
	userID, deviceID := uuid.NewString(), uuid.NewString()
	username := "user-" + userID
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := db.Exec(`INSERT INTO users (id,username,username_norm,password_hash,role,status,created_at,updated_at) VALUES (?,?,?,'hash','USER','ACTIVE',?,?)`,
		userID, username, username, now, now); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO devices (id,user_id,name,platform,e2ee_public_key,e2ee_key_version,created_at,last_seen_at) VALUES (?,?,?,'WINDOWS',?,1,?,?)`,
		deviceID, userID, "device", []byte("public-key"), now, now); err != nil {
		t.Fatal(err)
	}
	return userID, deviceID
}
