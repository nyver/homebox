package httpapi_test

import (
	"context"
	"encoding/base64"
	"net/http"
	"testing"
)

func TestReadOnlyFamilyShareAllowsBrowseAndRevokeRemovesAccess(t *testing.T) {
	s := startTestServer(t)
	member, err := s.auth.CreateUser(context.Background(), "member", testPassword)
	if err != nil {
		t.Fatal(err)
	}
	owner := loginDevice(t, s, "admin", "90000000-0000-0000-0000-000000000001")
	recipientDeviceID := "90000000-0000-0000-0000-000000000002"
	recipient := loginDevice(t, s, "member", recipientDeviceID)
	ownerToken := owner["accessToken"].(string)
	recipientToken := recipient["accessToken"].(string)
	folderID := "90000000-0000-0000-0000-000000000003"
	resp, folder := s.do(t, http.MethodPost, "/api/v1/nodes", map[string]any{
		"id": folderID, "operationId": "90000000-0000-0000-0000-000000000004", "nodeType": "DIRECTORY",
		"metadataCiphertext": base64.StdEncoding.EncodeToString([]byte("encrypted-shared-folder")), "metadataKeyVersion": 1,
	}, ownerToken)
	if resp.StatusCode != http.StatusCreated || folder["id"] != folderID {
		t.Fatalf("create shared folder status=%d body=%v", resp.StatusCode, folder)
	}
	resp, grant := s.do(t, http.MethodPost, "/api/v1/shares", map[string]any{
		"operationId": "90000000-0000-0000-0000-000000000005", "nodeId": folderID, "targetUserId": member.ID, "permission": "READ",
		"envelopes": []map[string]any{{"targetDeviceId": recipientDeviceID, "keyVersion": 1, "ciphertext": base64.StdEncoding.EncodeToString([]byte("recipient-encrypted-folder-key"))}},
	}, ownerToken)
	if resp.StatusCode != http.StatusCreated || grant["id"] == "" {
		t.Fatalf("create share status=%d body=%v", resp.StatusCode, grant)
	}
	resp, outgoingRaw := s.doRaw(t, http.MethodGet, "/api/v1/shares/outgoing", nil, ownerToken)
	if resp.StatusCode != http.StatusOK || len(decodeArray(t, outgoingRaw)) != 1 {
		t.Fatalf("outgoing shares status=%d body=%s", resp.StatusCode, outgoingRaw)
	}
	resp, incomingRaw := s.doRaw(t, http.MethodGet, "/api/v1/shares/incoming", nil, recipientToken)
	if resp.StatusCode != http.StatusOK || len(decodeArray(t, incomingRaw)) != 1 {
		t.Fatalf("incoming shares status=%d body=%s", resp.StatusCode, incomingRaw)
	}
	resp, receivedFolder := s.get(t, "/api/v1/nodes/"+folderID, recipientToken)
	if resp.StatusCode != http.StatusOK || receivedFolder["id"] != folderID {
		t.Fatalf("recipient get folder status=%d body=%v", resp.StatusCode, receivedFolder)
	}
	recipientRootID := "90000000-0000-0000-0000-000000000006"
	resp, _ = s.do(t, http.MethodPost, "/api/v1/nodes", map[string]any{
		"id": recipientRootID, "operationId": "90000000-0000-0000-0000-000000000007", "nodeType": "DIRECTORY",
		"metadataCiphertext": base64.StdEncoding.EncodeToString([]byte("encrypted-recipient-folder")), "metadataKeyVersion": 1,
	}, recipientToken)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create recipient root status=%d", resp.StatusCode)
	}
	resp, ownedRootsRaw := s.doRaw(t, http.MethodGet, "/api/v1/nodes/children?ownedOnly=true", nil, recipientToken)
	ownedRoots := decodeArray(t, ownedRootsRaw)
	if resp.StatusCode != http.StatusOK || len(ownedRoots) != 1 || ownedRoots[0]["id"] != recipientRootID {
		t.Fatalf("owned roots status=%d body=%s", resp.StatusCode, ownedRootsRaw)
	}
	resp, _ = s.doRaw(t, http.MethodDelete, "/api/v1/shares/"+grant["id"].(string), nil, ownerToken)
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("revoke status=%d", resp.StatusCode)
	}
	resp, denied := s.get(t, "/api/v1/nodes/"+folderID, recipientToken)
	if resp.StatusCode != http.StatusForbidden || denied["error"] == nil {
		t.Fatalf("revoked recipient status=%d body=%v", resp.StatusCode, denied)
	}
}
