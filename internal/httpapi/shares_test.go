package httpapi_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"testing"
)

func b64(v string) string { return base64.StdEncoding.EncodeToString([]byte(v)) }

// signedEnvelope is a structurally valid share envelope. The server only
// checks sizes; the real signature is verified by the recipient's client.
func signedEnvelope(deviceID string, keyVersion int, ciphertext string) map[string]any {
	return map[string]any{
		"targetDeviceId": deviceID, "keyVersion": keyVersion, "ciphertext": b64(ciphertext),
		"ownerIdentityPublicKey": base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32)),
		"ownerSignature":         base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{9}, 64)),
	}
}

func createFolderKeyOverHTTP(t *testing.T, s testServer, token, folderID string, version int) {
	t.Helper()
	resp, body := s.do(t, http.MethodPost, "/api/v1/nodes/"+folderID+"/folder-keys", map[string]any{
		"keyVersion": version, "ownerEnvelope": b64("owner-wrapped-folder-key"),
	}, token)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create folder key v%d status=%d body=%v", version, resp.StatusCode, body)
	}
}

// shareFolderOverHTTP turns folderID into a key scope (if needed) and
// shares it with one recipient device.
func shareFolderOverHTTP(t *testing.T, s testServer, token, folderID, operationID, targetUserID, deviceID, permission string) map[string]any {
	t.Helper()
	resp, keys := s.doRaw(t, http.MethodGet, "/api/v1/folder-keys", nil, token)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("list folder keys status=%d", resp.StatusCode)
	}
	keyed := false
	for _, key := range decodeArray(t, keys) {
		keyed = keyed || key["folderId"] == folderID
	}
	if !keyed {
		createFolderKeyOverHTTP(t, s, token, folderID, 1)
	}
	resp, grant := s.do(t, http.MethodPost, "/api/v1/shares", map[string]any{
		"operationId": operationID, "nodeId": folderID, "targetUserId": targetUserID, "permission": permission,
		"envelopes": []map[string]any{signedEnvelope(deviceID, 1, "recipient-encrypted-folder-key")},
	}, token)
	if resp.StatusCode != http.StatusCreated || grant["id"] == "" {
		t.Fatalf("create share status=%d body=%v", resp.StatusCode, grant)
	}
	return grant
}

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
	createNodeOverHTTP(t, s, ownerToken, folderID, "90000000-0000-0000-0000-000000000004", "DIRECTORY", "")

	// A folder without a key cannot be shared: its content would be
	// encrypted with the owner's personal Vault Key.
	resp, refused := s.do(t, http.MethodPost, "/api/v1/shares", map[string]any{
		"operationId": "90000000-0000-0000-0000-0000000000f1", "nodeId": folderID, "targetUserId": member.ID, "permission": "READ",
		"envelopes": []map[string]any{signedEnvelope(recipientDeviceID, 1, "k")},
	}, ownerToken)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("unkeyed share status=%d body=%v", resp.StatusCode, refused)
	}
	grant := shareFolderOverHTTP(t, s, ownerToken, folderID, "90000000-0000-0000-0000-000000000005", member.ID, recipientDeviceID, "READ")
	if grant["ownerUsername"] != "admin" || grant["targetUsername"] != "member" {
		t.Fatalf("share usernames=%v", grant)
	}
	resp, outgoingRaw := s.doRaw(t, http.MethodGet, "/api/v1/shares/outgoing", nil, ownerToken)
	if resp.StatusCode != http.StatusOK || len(decodeArray(t, outgoingRaw)) != 1 {
		t.Fatalf("outgoing shares status=%d body=%s", resp.StatusCode, outgoingRaw)
	}
	resp, incomingRaw := s.doRaw(t, http.MethodGet, "/api/v1/shares/incoming", nil, recipientToken)
	incoming := decodeArray(t, incomingRaw)
	if resp.StatusCode != http.StatusOK || len(incoming) != 1 {
		t.Fatalf("incoming shares status=%d body=%s", resp.StatusCode, incomingRaw)
	}
	envelopes := incoming[0]["envelopes"].([]any)
	if len(envelopes) != 1 || envelopes[0].(map[string]any)["ownerSignature"] == "" {
		t.Fatalf("incoming envelopes=%v", envelopes)
	}
	resp, receivedFolder := s.get(t, "/api/v1/nodes/"+folderID, recipientToken)
	if resp.StatusCode != http.StatusOK || receivedFolder["id"] != folderID {
		t.Fatalf("recipient get folder status=%d body=%v", resp.StatusCode, receivedFolder)
	}
	// READ does not allow adding content.
	resp, _ = s.do(t, http.MethodPost, "/api/v1/nodes", map[string]any{
		"id": "90000000-0000-0000-0000-0000000000f2", "operationId": "90000000-0000-0000-0000-0000000000f3", "parentId": folderID,
		"nodeType": "FILE", "metadataCiphertext": b64("m"), "metadataKeyVersion": 1, "metadataKeyScopeId": folderID,
	}, recipientToken)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("READ recipient create status=%d, want 400", resp.StatusCode)
	}
	recipientRootID := "90000000-0000-0000-0000-000000000006"
	createNodeOverHTTP(t, s, recipientToken, recipientRootID, "90000000-0000-0000-0000-000000000007", "DIRECTORY", "")
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

func TestReadWriteShareLetsAMemberChangeContentBelowTheSharedFolder(t *testing.T) {
	s := startTestServer(t)
	member, err := s.auth.CreateUser(context.Background(), "member", testPassword)
	if err != nil {
		t.Fatal(err)
	}
	ownerToken := loginDevice(t, s, "admin", "91000000-0000-4000-8000-000000000001")["accessToken"].(string)
	memberDevice := "91000000-0000-4000-8000-000000000002"
	memberToken := loginDevice(t, s, "member", memberDevice)["accessToken"].(string)
	ownerID := accountIDOf(t, s, ownerToken)
	folderID := "91000000-0000-4000-8000-000000000010"
	createNodeOverHTTP(t, s, ownerToken, folderID, "91000000-0000-4000-8000-000000000011", "DIRECTORY", "")
	shareFolderOverHTTP(t, s, ownerToken, folderID, "91000000-0000-4000-8000-000000000012", member.ID, memberDevice, "READ_WRITE")

	createAs := func(token, id, operationID, nodeType, parentID, scope string) (*http.Response, map[string]any) {
		return s.do(t, http.MethodPost, "/api/v1/nodes", map[string]any{
			"id": id, "operationId": operationID, "parentId": parentID, "nodeType": nodeType,
			"metadataCiphertext": b64("encrypted"), "metadataKeyVersion": 1, "metadataKeyScopeId": scope,
		}, token)
	}
	// The member's content must be encrypted with the folder key, never
	// with a key only some members hold.
	if resp, _ := createAs(memberToken, "91000000-0000-4000-8000-000000000020", "91000000-0000-4000-8000-000000000021", "DIRECTORY", folderID, member.ID); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("member create with its own vault scope status=%d, want 400", resp.StatusCode)
	}
	resp, sub := createAs(memberToken, "91000000-0000-4000-8000-000000000022", "91000000-0000-4000-8000-000000000023", "DIRECTORY", folderID, folderID)
	if resp.StatusCode != http.StatusCreated || sub["metadataKeyScopeId"] != folderID {
		t.Fatalf("member create folder status=%d body=%v", resp.StatusCode, sub)
	}
	resp, file := createAs(memberToken, "91000000-0000-4000-8000-000000000024", "91000000-0000-4000-8000-000000000025", "FILE", sub["id"].(string), folderID)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("member create file status=%d body=%v", resp.StatusCode, file)
	}
	fileID := file["id"].(string)

	// The member's new nodes live in the owner's tree and sync feed.
	resp, ownerView := s.get(t, "/api/v1/nodes/"+fileID, ownerToken)
	if resp.StatusCode != http.StatusOK || ownerView["metadataKeyScopeId"] != folderID {
		t.Fatalf("owner view of member file status=%d body=%v", resp.StatusCode, ownerView)
	}
	resp, feed := s.get(t, "/api/v1/sync/changes?after=0", ownerToken)
	if resp.StatusCode != http.StatusOK || len(feed["changes"].([]any)) < 3 {
		t.Fatalf("owner sync feed status=%d body=%v", resp.StatusCode, feed)
	}

	// Upload content as the member, under the folder key.
	resp, upload := s.do(t, http.MethodPost, "/api/v1/uploads", map[string]any{
		"targetNodeId": fileID, "fileVersionId": "91000000-0000-4000-8000-000000000030", "blobId": "91000000-0000-4000-8000-000000000031",
		"expectedRevision": int64(file["revision"].(float64)), "chunkSize": 4, "chunkCount": 1, "metadataKeyVersion": 1,
		"metadataCiphertext": b64("m"), "wrappedFileKey": b64("k"), "e2eeHeader": b64("h"),
	}, memberToken)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("member create upload status=%d body=%v", resp.StatusCode, upload)
	}
	uploadID := upload["id"].(string)
	if resp, _ := s.doRaw(t, http.MethodPut, "/api/v1/uploads/"+uploadID+"/chunks/0", []byte("data"), memberToken); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("member put chunk status=%d", resp.StatusCode)
	}
	completeBody := func(scope string) map[string]any {
		return map[string]any{"operationId": "91000000-0000-4000-8000-0000000000" + scope[:2], "keyScopeId": scope, "keyVersion": 1,
			"expectedRevision": int64(file["revision"].(float64))}
	}
	if resp, _ := s.do(t, http.MethodPost, "/api/v1/uploads/"+uploadID+"/complete", completeBody(ownerID), memberToken); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("member complete with the owner's vault scope status=%d, want 400", resp.StatusCode)
	}
	if resp, body := s.do(t, http.MethodPost, "/api/v1/uploads/"+uploadID+"/complete", completeBody(folderID), memberToken); resp.StatusCode != http.StatusOK {
		t.Fatalf("member complete status=%d body=%v", resp.StatusCode, body)
	}

	// The member can rename inside the share but not touch the root, and
	// cannot move anything out of it.
	resp, current := s.get(t, "/api/v1/nodes/"+sub["id"].(string), memberToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("member get status=%d", resp.StatusCode)
	}
	if resp, body := s.do(t, http.MethodPatch, "/api/v1/nodes/"+sub["id"].(string), map[string]any{
		"operationId": "91000000-0000-4000-8000-000000000040", "expectedRevision": current["revision"],
		"metadataCiphertext": b64("renamed"), "metadataKeyVersion": 1, "metadataKeyScopeId": folderID,
	}, memberToken); resp.StatusCode != http.StatusOK {
		t.Fatalf("member rename status=%d body=%v", resp.StatusCode, body)
	}
	resp, root := s.get(t, "/api/v1/nodes/"+folderID, memberToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("member get root status=%d", resp.StatusCode)
	}
	if resp, _ := s.do(t, http.MethodDelete, "/api/v1/nodes/"+folderID, map[string]any{
		"operationId": "91000000-0000-4000-8000-000000000041", "expectedRevision": root["revision"],
	}, memberToken); resp.StatusCode != http.StatusForbidden {
		t.Fatalf("member delete of the shared root status=%d, want 403", resp.StatusCode)
	}
	resp, current = s.get(t, "/api/v1/nodes/"+fileID, memberToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("member get file status=%d", resp.StatusCode)
	}
	if resp, _ := s.do(t, http.MethodPatch, "/api/v1/nodes/"+fileID, map[string]any{
		"operationId": "91000000-0000-4000-8000-000000000042", "expectedRevision": current["revision"], "moveParent": true, "parentId": nil,
	}, memberToken); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("member move out of the share status=%d, want 400", resp.StatusCode)
	}
	if resp, _ := s.do(t, http.MethodDelete, "/api/v1/nodes/"+fileID, map[string]any{
		"operationId": "91000000-0000-4000-8000-000000000043", "expectedRevision": current["revision"],
	}, memberToken); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("member delete status=%d", resp.StatusCode)
	}
	resp, trashRaw := s.doRaw(t, http.MethodGet, "/api/v1/trash", nil, ownerToken)
	if resp.StatusCode != http.StatusOK || len(decodeArray(t, trashRaw)) != 1 {
		t.Fatalf("owner trash status=%d body=%s", resp.StatusCode, trashRaw)
	}

	// After a rotation, a member may add content only with the newest key:
	// a removed member still holds version 1.
	createFolderKeyOverHTTP(t, s, ownerToken, folderID, 2)
	createWithVersion := func(id, operationID string, version int) *http.Response {
		resp, _ := s.do(t, http.MethodPost, "/api/v1/nodes", map[string]any{
			"id": id, "operationId": operationID, "parentId": folderID, "nodeType": "DIRECTORY",
			"metadataCiphertext": b64("encrypted"), "metadataKeyVersion": version, "metadataKeyScopeId": folderID,
		}, memberToken)
		return resp
	}
	if resp := createWithVersion("91000000-0000-4000-8000-000000000050", "91000000-0000-4000-8000-000000000051", 1); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("member create with a superseded key status=%d, want 400", resp.StatusCode)
	}
	if resp := createWithVersion("91000000-0000-4000-8000-000000000052", "91000000-0000-4000-8000-000000000053", 2); resp.StatusCode != http.StatusCreated {
		t.Fatalf("member create with the newest key status=%d, want 201", resp.StatusCode)
	}
	// The owner keeps using whatever version its device has.
	resp, _ = s.do(t, http.MethodPost, "/api/v1/nodes", map[string]any{
		"id": "91000000-0000-4000-8000-000000000054", "operationId": "91000000-0000-4000-8000-000000000055", "parentId": folderID,
		"nodeType": "DIRECTORY", "metadataCiphertext": b64("encrypted"), "metadataKeyVersion": 1, "metadataKeyScopeId": folderID,
	}, ownerToken)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("owner create with an older key status=%d, want 201", resp.StatusCode)
	}
	// A concurrent rotation to an existing version conflicts instead of failing.
	if resp, _ := s.do(t, http.MethodPost, "/api/v1/nodes/"+folderID+"/folder-keys", map[string]any{"keyVersion": 2, "ownerEnvelope": b64("other-device")}, ownerToken); resp.StatusCode != http.StatusConflict {
		t.Fatalf("concurrent rotation status=%d, want 409", resp.StatusCode)
	}
}

func TestFolderKeysRekeyRotationAndNestingRules(t *testing.T) {
	s := startTestServer(t)
	member, err := s.auth.CreateUser(context.Background(), "member", testPassword)
	if err != nil {
		t.Fatal(err)
	}
	ownerToken := loginDevice(t, s, "admin", "92000000-0000-4000-8000-000000000001")["accessToken"].(string)
	memberDevice := "92000000-0000-4000-8000-000000000002"
	memberToken := loginDevice(t, s, "member", memberDevice)["accessToken"].(string)
	ownerID := accountIDOf(t, s, ownerToken)
	outer := createNodeOverHTTP(t, s, ownerToken, "92000000-0000-4000-8000-000000000010", "92000000-0000-4000-8000-000000000011", "DIRECTORY", "")
	inner := createNodeOverHTTP(t, s, ownerToken, "92000000-0000-4000-8000-000000000012", "92000000-0000-4000-8000-000000000013", "DIRECTORY", outer["id"].(string))
	other := createNodeOverHTTP(t, s, ownerToken, "92000000-0000-4000-8000-000000000014", "92000000-0000-4000-8000-000000000015", "DIRECTORY", "")
	outerID, innerID, otherID := outer["id"].(string), inner["id"].(string), other["id"].(string)

	createFolderKeyOverHTTP(t, s, ownerToken, outerID, 1)
	// Retrying the same key is idempotent; a different envelope is not.
	createFolderKeyOverHTTP(t, s, ownerToken, outerID, 1)
	if resp, _ := s.do(t, http.MethodPost, "/api/v1/nodes/"+outerID+"/folder-keys", map[string]any{"keyVersion": 1, "ownerEnvelope": b64("different")}, ownerToken); resp.StatusCode != http.StatusConflict {
		t.Fatalf("conflicting folder key status=%d, want 409", resp.StatusCode)
	}
	if resp, _ := s.do(t, http.MethodPost, "/api/v1/nodes/"+outerID+"/folder-keys", map[string]any{"keyVersion": 3, "ownerEnvelope": b64("skip")}, ownerToken); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("skipped folder key version status=%d, want 400", resp.StatusCode)
	}
	if resp, _ := s.do(t, http.MethodPost, "/api/v1/nodes/"+innerID+"/folder-keys", map[string]any{"keyVersion": 1, "ownerEnvelope": b64("nested")}, ownerToken); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("nested folder key status=%d, want 400", resp.StatusCode)
	}
	if resp, _ := s.do(t, http.MethodPost, "/api/v1/nodes/"+outerID+"/folder-keys", map[string]any{"keyVersion": 1, "ownerEnvelope": b64("x")}, memberToken); resp.StatusCode != http.StatusForbidden {
		t.Fatalf("foreign folder key status=%d, want 403", resp.StatusCode)
	}

	// Rekey the inner folder into the outer folder's scope.
	rekey := func(token string, revision any, scope string) (*http.Response, []byte) {
		body, err := json.Marshal(map[string]any{"items": []map[string]any{{
			"nodeId": innerID, "expectedRevision": revision, "metadataCiphertext": b64("rekeyed"), "metadataKeyVersion": 1, "metadataKeyScopeId": scope,
		}}})
		if err != nil {
			t.Fatal(err)
		}
		return s.doRaw(t, http.MethodPost, "/api/v1/nodes/rekey", body, token)
	}
	if resp, _ := rekey(memberToken, inner["revision"], outerID); resp.StatusCode != http.StatusForbidden {
		t.Fatalf("foreign rekey status=%d, want 403", resp.StatusCode)
	}
	if resp, _ := rekey(ownerToken, inner["revision"], otherID); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("rekey into an unkeyed scope status=%d, want 400", resp.StatusCode)
	}
	resp, rekeyed := rekey(ownerToken, inner["revision"], outerID)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("rekey status=%d body=%s", resp.StatusCode, rekeyed)
	}
	if got := decodeArray(t, rekeyed)[0]["metadataKeyScopeId"]; got != outerID {
		t.Fatalf("rekeyed scope=%v", got)
	}
	if resp, _ := rekey(ownerToken, inner["revision"], outerID); resp.StatusCode != http.StatusConflict {
		t.Fatalf("stale rekey retry status=%d, want 409", resp.StatusCode)
	}

	// Moving a shared folder into another one would nest key scopes.
	createFolderKeyOverHTTP(t, s, ownerToken, otherID, 1)
	resp, current := s.get(t, "/api/v1/nodes/"+otherID, ownerToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatal("get other folder failed")
	}
	if resp, _ := s.do(t, http.MethodPatch, "/api/v1/nodes/"+otherID, map[string]any{
		"operationId": "92000000-0000-4000-8000-000000000020", "expectedRevision": current["revision"], "moveParent": true, "parentId": outerID,
	}, ownerToken); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("nesting move status=%d, want 400", resp.StatusCode)
	}

	// Rotation: version 2 of the key and a new envelope for the member.
	grant := shareFolderOverHTTP(t, s, ownerToken, outerID, "92000000-0000-4000-8000-000000000030", member.ID, memberDevice, "READ")
	createFolderKeyOverHTTP(t, s, ownerToken, outerID, 2)
	resp, updated := s.do(t, http.MethodPost, "/api/v1/shares/"+grant["id"].(string)+"/envelopes", map[string]any{
		"envelopes": []map[string]any{signedEnvelope(memberDevice, 2, "rotated"), signedEnvelope(memberDevice, 1, "duplicate-is-kept")},
	}, ownerToken)
	if resp.StatusCode != http.StatusOK || len(updated["envelopes"].([]any)) != 2 {
		t.Fatalf("add envelopes status=%d body=%v", resp.StatusCode, updated)
	}
	if resp, _ := s.do(t, http.MethodPost, "/api/v1/shares/"+grant["id"].(string)+"/envelopes", map[string]any{
		"envelopes": []map[string]any{signedEnvelope(memberDevice, 5, "missing-key")},
	}, ownerToken); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("envelope for a missing key version status=%d, want 400", resp.StatusCode)
	}
	resp, keysRaw := s.doRaw(t, http.MethodGet, "/api/v1/folder-keys", nil, ownerToken)
	if resp.StatusCode != http.StatusOK || len(decodeArray(t, keysRaw)) != 3 {
		t.Fatalf("folder keys status=%d body=%s", resp.StatusCode, keysRaw)
	}
	// The owner's own personal-vault scope stays valid for owner writes.
	resp, _ = s.do(t, http.MethodPost, "/api/v1/nodes", map[string]any{
		"id": "92000000-0000-4000-8000-000000000040", "operationId": "92000000-0000-4000-8000-000000000041", "nodeType": "DIRECTORY",
		"metadataCiphertext": b64("m"), "metadataKeyVersion": 1, "metadataKeyScopeId": ownerID,
	}, ownerToken)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("owner create with vault scope status=%d", resp.StatusCode)
	}
}
