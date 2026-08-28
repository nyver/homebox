package sharing

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/homebox/homebox/internal/database"
	"github.com/homebox/homebox/internal/nodes"
)

func TestReadGrantDeliversEnvelopeAndAuthorizesSharedSubtree(t *testing.T) {
	ctx := context.Background()
	db, err := database.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ownerID, recipientID := uuid.NewString(), uuid.NewString()
	ownerDeviceID, recipientDeviceID := uuid.NewString(), uuid.NewString()
	now := time.Now().UTC().Format(time.RFC3339Nano)
	for _, user := range []struct{ id, username, role string }{{ownerID, "owner", "ADMIN"}, {recipientID, "recipient", "USER"}} {
		if _, err := db.Exec(`INSERT INTO users (id,username,username_norm,password_hash,role,status,created_at,updated_at) VALUES (?,?,?,'hash',?,'ACTIVE',?,?)`, user.id, user.username, user.username, user.role, now, now); err != nil {
			t.Fatal(err)
		}
	}
	for _, device := range []struct{ id, userID string }{{ownerDeviceID, ownerID}, {recipientDeviceID, recipientID}} {
		if _, err := db.Exec(`INSERT INTO devices (id,user_id,name,platform,e2ee_public_key,e2ee_key_version,created_at,last_seen_at) VALUES (?,?,?,'WINDOWS',X'01',1,?,?)`, device.id, device.userID, "device", now, now); err != nil {
			t.Fatal(err)
		}
	}
	folderID, childID := uuid.NewString(), uuid.NewString()
	if _, err := db.Exec(`INSERT INTO nodes (id,owner_id,node_type,metadata_ciphertext,metadata_key_version,revision,created_at,updated_at) VALUES (?,?, 'DIRECTORY',X'01',1,1,?,?)`, folderID, ownerID, now, now); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO nodes (id,owner_id,parent_id,node_type,metadata_ciphertext,metadata_key_version,revision,created_at,updated_at) VALUES (?,?,?,'FILE',X'02',1,2,?,?)`, childID, ownerID, folderID, now, now); err != nil {
		t.Fatal(err)
	}

	service := New(db)
	operationID := uuid.NewString()
	grant, err := service.CreateReadGrant(ctx, CreateInput{OwnerUserID: ownerID, OwnerDeviceID: ownerDeviceID, OperationID: operationID, NodeID: folderID, TargetUserID: recipientID, Permission: "READ", Envelopes: []DeviceEnvelope{{TargetDeviceID: recipientDeviceID, KeyVersion: 1, Ciphertext: []byte("recipient-encrypted-folder-key")}}})
	if err != nil {
		t.Fatal(err)
	}
	retry, err := service.CreateReadGrant(ctx, CreateInput{OwnerUserID: ownerID, OwnerDeviceID: ownerDeviceID, OperationID: operationID, NodeID: folderID, TargetUserID: recipientID, Permission: "READ", Envelopes: []DeviceEnvelope{{TargetDeviceID: recipientDeviceID, KeyVersion: 1, Ciphertext: []byte("recipient-encrypted-folder-key")}}})
	if err != nil || retry.ID != grant.ID {
		t.Fatalf("idempotent grant=%#v err=%v", retry, err)
	}
	incoming, err := service.ListIncoming(ctx, recipientID, recipientDeviceID)
	if err != nil || len(incoming) != 1 || string(incoming[0].Envelopes[0].Ciphertext) != "recipient-encrypted-folder-key" {
		t.Fatalf("incoming=%#v err=%v", incoming, err)
	}
	if _, err := nodes.New(db).Get(ctx, recipientID, childID); err != nil {
		t.Fatalf("recipient could not read shared descendant: %v", err)
	}
	roots, err := nodes.New(db).ListChildren(ctx, recipientID, nil)
	if err != nil || len(roots) != 1 || roots[0].ID != folderID {
		t.Fatalf("shared roots=%#v err=%v", roots, err)
	}
	children, err := nodes.New(db).ListChildren(ctx, recipientID, &folderID)
	if err != nil || len(children) != 1 || children[0].ID != childID {
		t.Fatalf("shared children=%#v err=%v", children, err)
	}
	if err := service.Revoke(ctx, ownerID, ownerDeviceID, grant.ID); err != nil {
		t.Fatal(err)
	}
	if err := service.Revoke(ctx, ownerID, ownerDeviceID, grant.ID); err != nil {
		t.Fatalf("revoke retry must be idempotent: %v", err)
	}
	if _, err := nodes.New(db).Get(ctx, recipientID, childID); err != nodes.ErrForbidden {
		t.Fatalf("revoked recipient read err=%v", err)
	}
	if incoming, err := service.ListIncoming(ctx, recipientID, recipientDeviceID); err != nil || len(incoming) != 0 {
		t.Fatalf("incoming after revoke=%#v err=%v", incoming, err)
	}
}

func TestCreateReadGrantRejectsReadWriteUntilSharedMutationsExist(t *testing.T) {
	db, err := database.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	service := New(db)
	if _, err := service.CreateReadGrant(context.Background(), CreateInput{Permission: "READ_WRITE"}); err == nil {
		t.Fatal("READ_WRITE share was accepted")
	}
}
