package nodes

import (
	"context"
	"database/sql"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/homebox/homebox/internal/database"
)

func newTestService(t *testing.T) (*Service, *sql.DB, string, string) {
	t.Helper()
	db, err := database.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	userID, deviceID := seedUserAndDevice(t, db)
	return New(db), db, userID, deviceID
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

func TestCreateRootDirectoryAndChild(t *testing.T) {
	ctx := context.Background()
	s, _, userID, deviceID := newTestService(t)

	dir, err := s.Create(ctx, CreateInput{ID: uuid.NewString(), OwnerID: userID, DeviceID: deviceID, OperationID: uuid.NewString(),
		NodeType: "DIRECTORY", MetadataCiphertext: []byte("encrypted-folder-name"), MetadataKeyVersion: 1})
	if err != nil {
		t.Fatal(err)
	}
	if dir.ParentID != nil || dir.Revision < 1 {
		t.Fatalf("unexpected root directory: %#v", dir)
	}

	child, err := s.Create(ctx, CreateInput{ID: uuid.NewString(), OwnerID: userID, DeviceID: deviceID, OperationID: uuid.NewString(),
		ParentID: &dir.ID, NodeType: "FILE", MetadataCiphertext: []byte("encrypted-file-name"), MetadataKeyVersion: 1})
	if err != nil {
		t.Fatal(err)
	}
	if child.ParentID == nil || *child.ParentID != dir.ID {
		t.Fatalf("child parent mismatch: %#v", child)
	}

	children, err := s.ListChildren(ctx, userID, &dir.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(children) != 1 || children[0].ID != child.ID {
		t.Fatalf("unexpected children: %#v", children)
	}

	roots, err := s.ListChildren(ctx, userID, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(roots) != 1 || roots[0].ID != dir.ID {
		t.Fatalf("unexpected roots: %#v", roots)
	}
}

func TestCreateIsIdempotent(t *testing.T) {
	ctx := context.Background()
	s, _, userID, deviceID := newTestService(t)
	operationID := uuid.NewString()
	in := CreateInput{ID: uuid.NewString(), OwnerID: userID, DeviceID: deviceID, OperationID: operationID,
		NodeType: "DIRECTORY", MetadataCiphertext: []byte("m"), MetadataKeyVersion: 1}
	first, err := s.Create(ctx, in)
	if err != nil {
		t.Fatal(err)
	}
	second, err := s.Create(ctx, in)
	if err != nil {
		t.Fatal(err)
	}
	if first.ID != second.ID || first.Revision != second.Revision {
		t.Fatalf("retry produced a different result: %#v vs %#v", first, second)
	}
}

func TestCreateRejectsParentOwnedByAnotherUser(t *testing.T) {
	ctx := context.Background()
	s, db, userID, deviceID := newTestService(t)
	otherUserID, otherDeviceID := seedUserAndDevice(t, db)
	theirDir, err := s.Create(ctx, CreateInput{ID: uuid.NewString(), OwnerID: otherUserID, DeviceID: otherDeviceID, OperationID: uuid.NewString(),
		NodeType: "DIRECTORY", MetadataCiphertext: []byte("m"), MetadataKeyVersion: 1})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Create(ctx, CreateInput{ID: uuid.NewString(), OwnerID: userID, DeviceID: deviceID, OperationID: uuid.NewString(),
		ParentID: &theirDir.ID, NodeType: "FILE", MetadataCiphertext: []byte("m"), MetadataKeyVersion: 1}); err != ErrInvalidParent {
		t.Fatalf("error=%v, want %v", err, ErrInvalidParent)
	}
}

func TestUpdateRenameAndMoveRequireExpectedRevision(t *testing.T) {
	ctx := context.Background()
	s, _, userID, deviceID := newTestService(t)
	dirA, err := s.Create(ctx, CreateInput{ID: uuid.NewString(), OwnerID: userID, DeviceID: deviceID, OperationID: uuid.NewString(),
		NodeType: "DIRECTORY", MetadataCiphertext: []byte("a"), MetadataKeyVersion: 1})
	if err != nil {
		t.Fatal(err)
	}
	dirB, err := s.Create(ctx, CreateInput{ID: uuid.NewString(), OwnerID: userID, DeviceID: deviceID, OperationID: uuid.NewString(),
		NodeType: "DIRECTORY", MetadataCiphertext: []byte("b"), MetadataKeyVersion: 1})
	if err != nil {
		t.Fatal(err)
	}
	file, err := s.Create(ctx, CreateInput{ID: uuid.NewString(), OwnerID: userID, DeviceID: deviceID, OperationID: uuid.NewString(),
		ParentID: &dirA.ID, NodeType: "FILE", MetadataCiphertext: []byte("name1"), MetadataKeyVersion: 1})
	if err != nil {
		t.Fatal(err)
	}

	if _, err := s.Update(ctx, UpdateInput{UserID: userID, DeviceID: deviceID, OperationID: uuid.NewString(), NodeID: file.ID,
		ExpectedRevision: file.Revision - 1, MetadataCiphertext: []byte("name2"), MetadataKeyVersion: 1}); err != ErrRevisionConflict {
		t.Fatalf("error=%v, want %v", err, ErrRevisionConflict)
	}

	moved, err := s.Update(ctx, UpdateInput{UserID: userID, DeviceID: deviceID, OperationID: uuid.NewString(), NodeID: file.ID,
		ExpectedRevision: file.Revision, MetadataCiphertext: []byte("name2"), MetadataKeyVersion: 1, MoveParent: true, ParentID: &dirB.ID})
	if err != nil {
		t.Fatal(err)
	}
	if moved.ParentID == nil || *moved.ParentID != dirB.ID || string(moved.MetadataCiphertext) != "name2" {
		t.Fatalf("unexpected moved node: %#v", moved)
	}
	if moved.Revision <= file.Revision {
		t.Fatalf("revision did not advance: %d -> %d", file.Revision, moved.Revision)
	}
}

func TestMoveRejectsCycle(t *testing.T) {
	ctx := context.Background()
	s, _, userID, deviceID := newTestService(t)
	parent, err := s.Create(ctx, CreateInput{ID: uuid.NewString(), OwnerID: userID, DeviceID: deviceID, OperationID: uuid.NewString(),
		NodeType: "DIRECTORY", MetadataCiphertext: []byte("p"), MetadataKeyVersion: 1})
	if err != nil {
		t.Fatal(err)
	}
	child, err := s.Create(ctx, CreateInput{ID: uuid.NewString(), OwnerID: userID, DeviceID: deviceID, OperationID: uuid.NewString(),
		ParentID: &parent.ID, NodeType: "DIRECTORY", MetadataCiphertext: []byte("c"), MetadataKeyVersion: 1})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Update(ctx, UpdateInput{UserID: userID, DeviceID: deviceID, OperationID: uuid.NewString(), NodeID: parent.ID,
		ExpectedRevision: parent.Revision, MoveParent: true, ParentID: &child.ID}); err == nil {
		t.Fatal("expected moving a directory under its own child to fail")
	}
}

func TestDeleteAndRestore(t *testing.T) {
	ctx := context.Background()
	s, _, userID, deviceID := newTestService(t)
	dir, err := s.Create(ctx, CreateInput{ID: uuid.NewString(), OwnerID: userID, DeviceID: deviceID, OperationID: uuid.NewString(),
		NodeType: "DIRECTORY", MetadataCiphertext: []byte("d"), MetadataKeyVersion: 1})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Delete(ctx, userID, deviceID, dir.ID, uuid.NewString(), dir.Revision); err != nil {
		t.Fatal(err)
	}
	if roots, err := s.ListChildren(ctx, userID, nil); err != nil || len(roots) != 0 {
		t.Fatalf("deleted directory should not be listed: roots=%#v err=%v", roots, err)
	}
	trash, err := s.ListTrash(ctx, userID)
	if err != nil || len(trash) != 1 || trash[0].ID != dir.ID {
		t.Fatalf("unexpected trash contents: %#v err=%v", trash, err)
	}

	restored, err := s.Restore(ctx, userID, deviceID, dir.ID, uuid.NewString())
	if err != nil {
		t.Fatal(err)
	}
	if restored.IsDeleted() {
		t.Fatal("restored node still marked deleted")
	}
	if roots, err := s.ListChildren(ctx, userID, nil); err != nil || len(roots) != 1 {
		t.Fatalf("restored directory should be listed again: roots=%#v err=%v", roots, err)
	}
}

func TestDeleteRejectsStaleRevision(t *testing.T) {
	ctx := context.Background()
	s, _, userID, deviceID := newTestService(t)
	dir, err := s.Create(ctx, CreateInput{ID: uuid.NewString(), OwnerID: userID, DeviceID: deviceID, OperationID: uuid.NewString(),
		NodeType: "DIRECTORY", MetadataCiphertext: []byte("d"), MetadataKeyVersion: 1})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Delete(ctx, userID, deviceID, dir.ID, uuid.NewString(), dir.Revision-1); err != ErrRevisionConflict {
		t.Fatalf("error=%v, want %v", err, ErrRevisionConflict)
	}
}

func TestGetRejectsAnotherAccountsNode(t *testing.T) {
	ctx := context.Background()
	s, db, userID, deviceID := newTestService(t)
	otherUserID, _ := seedUserAndDevice(t, db)
	dir, err := s.Create(ctx, CreateInput{ID: uuid.NewString(), OwnerID: userID, DeviceID: deviceID, OperationID: uuid.NewString(),
		NodeType: "DIRECTORY", MetadataCiphertext: []byte("d"), MetadataKeyVersion: 1})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Get(ctx, otherUserID, dir.ID); err != ErrForbidden {
		t.Fatalf("error=%v, want %v", err, ErrForbidden)
	}
}
