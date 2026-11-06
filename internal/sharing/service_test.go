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
	if _, err := service.CreateFolderKey(ctx, ownerID, ownerDeviceID, folderID, 1, []byte("owner-wrapped-folder-key")); err != nil {
		t.Fatal(err)
	}
	operationID := uuid.NewString()
	grant, err := service.CreateGrant(ctx, CreateInput{OwnerUserID: ownerID, OwnerDeviceID: ownerDeviceID, OperationID: operationID, NodeID: folderID, TargetUserID: recipientID, Permission: "READ", Envelopes: []DeviceEnvelope{signed(recipientDeviceID, 1, "recipient-encrypted-folder-key")}})
	if err != nil {
		t.Fatal(err)
	}
	retry, err := service.CreateGrant(ctx, CreateInput{OwnerUserID: ownerID, OwnerDeviceID: ownerDeviceID, OperationID: operationID, NodeID: folderID, TargetUserID: recipientID, Permission: "READ", Envelopes: []DeviceEnvelope{signed(recipientDeviceID, 1, "recipient-encrypted-folder-key")}})
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

func signed(deviceID string, keyVersion int, ciphertext string) DeviceEnvelope {
	return DeviceEnvelope{TargetDeviceID: deviceID, KeyVersion: keyVersion, Ciphertext: []byte(ciphertext),
		OwnerIdentityPublicKey: make([]byte, ownerIdentityKeyLength), OwnerSignature: make([]byte, ownerSignatureLength)}
}

func TestCreateGrantValidatesPermissionAndSignatures(t *testing.T) {
	db, err := database.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	service := New(db)
	base := CreateInput{OwnerUserID: uuid.NewString(), OwnerDeviceID: uuid.NewString(), OperationID: uuid.NewString(), NodeID: uuid.NewString(), TargetUserID: uuid.NewString()}
	invalidPermission := base
	invalidPermission.Permission = "ADMIN"
	invalidPermission.Envelopes = []DeviceEnvelope{signed(uuid.NewString(), 1, "k")}
	if _, err := service.CreateGrant(context.Background(), invalidPermission); err == nil {
		t.Fatal("an unknown permission was accepted")
	}
	unsigned := base
	unsigned.Permission = "READ_WRITE"
	unsigned.Envelopes = []DeviceEnvelope{{TargetDeviceID: uuid.NewString(), KeyVersion: 1, Ciphertext: []byte("k")}}
	if _, err := service.CreateGrant(context.Background(), unsigned); err == nil {
		t.Fatal("an envelope without the owner's signature was accepted")
	}
}
