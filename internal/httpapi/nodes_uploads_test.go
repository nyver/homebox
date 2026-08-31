package httpapi_test

import (
	"encoding/base64"
	"fmt"
	"net/http"
	"testing"
)

func TestFullNodeUploadDownloadAndSyncFlow(t *testing.T) {
	s := startTestServer(t)
	session := loginDevice(t, s, "admin", "66666666-6666-6666-6666-666666666666")
	token := session["accessToken"].(string)

	// Create a root directory.
	resp, dir := s.do(t, http.MethodPost, "/api/v1/nodes", map[string]any{
		"id": "10000000-0000-0000-0000-000000000001", "operationId": "20000000-0000-0000-0000-000000000001",
		"nodeType": "DIRECTORY", "metadataCiphertext": base64.StdEncoding.EncodeToString([]byte("encrypted-folder")), "metadataKeyVersion": 1,
	}, token)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create directory status=%d body=%v", resp.StatusCode, dir)
	}
	dirID := dir["id"].(string)

	// Create a file node under it.
	resp, file := s.do(t, http.MethodPost, "/api/v1/nodes", map[string]any{
		"id": "10000000-0000-0000-0000-000000000002", "operationId": "20000000-0000-0000-0000-000000000002",
		"parentId": dirID, "nodeType": "FILE", "metadataCiphertext": base64.StdEncoding.EncodeToString([]byte("encrypted-file-name")), "metadataKeyVersion": 1,
	}, token)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create file node status=%d body=%v", resp.StatusCode, file)
	}
	fileID := file["id"].(string)
	fileRevision := int64(file["revision"].(float64))

	// List children of the directory.
	resp, childrenBody := s.doRaw(t, http.MethodGet, "/api/v1/nodes/children?parentId="+dirID, nil, token)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("list children status=%d", resp.StatusCode)
	}
	children := decodeArray(t, childrenBody)
	if len(children) != 1 || children[0]["id"] != fileID {
		t.Fatalf("unexpected children: %#v", children)
	}

	// Upload ciphertext content: two chunks.
	chunk0, chunk1 := []byte("first-ciphertext-chunk-"), []byte("second-ciphertext-chunk")
	blobID := "30000000-0000-0000-0000-000000000001"
	fileVersionID := "40000000-0000-0000-0000-000000000001"
	resp, uploadSession := s.do(t, http.MethodPost, "/api/v1/uploads", map[string]any{
		"targetNodeId": fileID, "fileVersionId": fileVersionID, "blobId": blobID,
		"expectedRevision": fileRevision, "chunkSize": len(chunk0), "chunkCount": 2, "metadataKeyVersion": 2,
		"metadataCiphertext": base64.StdEncoding.EncodeToString([]byte("m")),
		"wrappedFileKey":     base64.StdEncoding.EncodeToString([]byte("wrapped-file-key")),
		"e2eeHeader":         base64.StdEncoding.EncodeToString([]byte("e2ee-header")),
	}, token)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create upload status=%d body=%v", resp.StatusCode, uploadSession)
	}
	uploadID := uploadSession["id"].(string)

	for i, chunk := range [][]byte{chunk0, chunk1} {
		resp, _ := s.doRaw(t, http.MethodPut, fmt.Sprintf("/api/v1/uploads/%s/chunks/%d", uploadID, i), chunk, token)
		if resp.StatusCode != http.StatusNoContent {
			t.Fatalf("put chunk %d status=%d", i, resp.StatusCode)
		}
	}

	resp, completeBody := s.do(t, http.MethodPost, "/api/v1/uploads/"+uploadID+"/complete", map[string]any{
		"operationId": "50000000-0000-0000-0000-000000000001", "keyScopeId": "60000000-0000-0000-0000-000000000001",
		"keyVersion": 1, "expectedRevision": fileRevision,
	}, token)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("complete upload status=%d body=%v", resp.StatusCode, completeBody)
	}
	if completeBody["blobId"] != blobID {
		t.Fatalf("unexpected blob id: %v", completeBody["blobId"])
	}
	resp, updatedFile := s.get(t, "/api/v1/nodes/"+fileID, token)
	if resp.StatusCode != http.StatusOK || updatedFile["metadataKeyVersion"] != float64(2) || updatedFile["metadataCiphertext"] != base64.StdEncoding.EncodeToString([]byte("m")) {
		t.Fatalf("upload metadata was not committed with the file version: status=%d body=%v", resp.StatusCode, updatedFile)
	}

	// The version descriptor must carry back exactly what the client needs
	// to unwrap the File DEK and decrypt the blob it downloads.
	resp, versionsBody := s.doRaw(t, http.MethodGet, "/api/v1/files/"+fileID+"/versions", nil, token)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("list versions status=%d", resp.StatusCode)
	}
	versions := decodeArray(t, versionsBody)
	if len(versions) != 1 {
		t.Fatalf("expected exactly one file version, got %#v", versions)
	}
	version := versions[0]
	if version["id"] != fileVersionID || version["blobId"] != blobID {
		t.Fatalf("unexpected version descriptor: %#v", version)
	}
	if int(version["chunkCount"].(float64)) != 2 {
		t.Fatalf("unexpected chunkCount: %v", version["chunkCount"])
	}
	if decoded, err := base64.StdEncoding.DecodeString(version["wrappedFileKey"].(string)); err != nil || string(decoded) != "wrapped-file-key" {
		t.Fatalf("unexpected wrappedFileKey: %v (err=%v)", version["wrappedFileKey"], err)
	}
	if decoded, err := base64.StdEncoding.DecodeString(version["e2eeHeader"].(string)); err != nil || string(decoded) != "e2ee-header" {
		t.Fatalf("unexpected e2eeHeader: %v (err=%v)", version["e2eeHeader"], err)
	}

	// Download the content back and verify it matches the concatenated chunks byte-for-byte.
	resp, downloaded := s.doRaw(t, http.MethodGet, "/api/v1/files/"+fileID+"/content", nil, token)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("download status=%d", resp.StatusCode)
	}
	want := append(append([]byte{}, chunk0...), chunk1...)
	if string(downloaded) != string(want) {
		t.Fatalf("downloaded ciphertext mismatch: got %q want %q", downloaded, want)
	}
	resp, downloaded = s.doRaw(t, http.MethodGet, "/api/v1/files/"+fileID+"/content?versionId="+fileVersionID, nil, token)
	if resp.StatusCode != http.StatusOK || string(downloaded) != string(want) {
		t.Fatalf("version-pinned download status=%d got %q want %q", resp.StatusCode, downloaded, want)
	}

	// Rename+move the file back to root, then delete and restore it.
	resp, node := s.get(t, "/api/v1/nodes/"+fileID, token)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("get node status=%d", resp.StatusCode)
	}
	currentRevision := int64(node["revision"].(float64))

	resp, moved := s.do(t, http.MethodPatch, "/api/v1/nodes/"+fileID, map[string]any{
		"operationId": "70000000-0000-0000-0000-000000000001", "expectedRevision": currentRevision,
		"metadataCiphertext": base64.StdEncoding.EncodeToString([]byte("renamed")), "metadataKeyVersion": 1,
		"moveParent": true, "parentId": nil,
	}, token)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("update node status=%d body=%v", resp.StatusCode, moved)
	}
	if moved["parentId"] != nil {
		t.Fatalf("expected the node to move to root, got parentId=%v", moved["parentId"])
	}

	deleteRevision := int64(moved["revision"].(float64))
	resp, _ = s.do(t, http.MethodDelete, "/api/v1/nodes/"+fileID, map[string]any{
		"operationId": "80000000-0000-0000-0000-000000000001", "expectedRevision": deleteRevision,
	}, token)
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("delete node status=%d", resp.StatusCode)
	}
	resp, _ = s.doRaw(t, http.MethodGet, "/api/v1/files/"+fileID+"/content?versionId="+fileVersionID, nil, token)
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("trashed file download status=%d, want 404", resp.StatusCode)
	}

	resp, trashBody := s.doRaw(t, http.MethodGet, "/api/v1/trash", nil, token)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("list trash status=%d", resp.StatusCode)
	}
	if trashList := decodeArray(t, trashBody); len(trashList) != 1 || trashList[0]["id"] != fileID {
		t.Fatalf("unexpected trash contents: %#v", trashList)
	}

	resp, restored := s.do(t, http.MethodPost, "/api/v1/nodes/"+fileID+"/restore", map[string]any{
		"operationId": "90000000-0000-0000-0000-000000000001",
	}, token)
	if resp.StatusCode != http.StatusOK || restored["deletedAt"] != nil {
		t.Fatalf("restore node status=%d body=%v", resp.StatusCode, restored)
	}

	// The sync changes feed should show every mutation above, strictly ordered.
	resp, syncBody := s.get(t, "/api/v1/sync/changes?after=0&pageSize=100", token)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("sync changes status=%d", resp.StatusCode)
	}
	changes, _ := syncBody["changes"].([]any)
	if len(changes) < 5 {
		t.Fatalf("expected at least 5 sync changes (2 creates, upload complete, update, delete, restore), got %d: %#v", len(changes), changes)
	}
	var lastRevision float64
	for _, raw := range changes {
		entry := raw.(map[string]any)
		revision := entry["revision"].(float64)
		if revision <= lastRevision {
			t.Fatalf("sync changes are not strictly increasing: %#v", changes)
		}
		lastRevision = revision
	}
}
