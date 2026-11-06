package httpapi_test

import (
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"testing"
)

func removeBlob(s testServer, blobID string) error {
	return os.Remove(filepath.Join(s.storage, "blobs", blobID+".hbxblob"))
}

func createNodeOverHTTP(t *testing.T, s testServer, token, id, operationID, nodeType string, parentID string) map[string]any {
	t.Helper()
	body := map[string]any{
		"id": id, "operationId": operationID, "nodeType": nodeType,
		"metadataCiphertext": base64.StdEncoding.EncodeToString([]byte("encrypted")), "metadataKeyVersion": 1,
	}
	if parentID != "" {
		body["parentId"] = parentID
	}
	resp, node := s.do(t, http.MethodPost, "/api/v1/nodes", body, token)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create node %s status=%d body=%v", id, resp.StatusCode, node)
	}
	return node
}

func uploadOverHTTP(t *testing.T, s testServer, token, fileID string, revision int64, blobID, versionID string, content []byte) {
	t.Helper()
	resp, upload := s.do(t, http.MethodPost, "/api/v1/uploads", map[string]any{
		"targetNodeId": fileID, "fileVersionId": versionID, "blobId": blobID,
		"expectedRevision": revision, "chunkSize": len(content), "chunkCount": 1, "metadataKeyVersion": 1,
		"metadataCiphertext": base64.StdEncoding.EncodeToString([]byte("m")),
		"wrappedFileKey":     base64.StdEncoding.EncodeToString([]byte("k")),
		"e2eeHeader":         base64.StdEncoding.EncodeToString([]byte("h")),
	}, token)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create upload status=%d body=%v", resp.StatusCode, upload)
	}
	uploadID := upload["id"].(string)
	if resp, _ := s.doRaw(t, http.MethodPut, "/api/v1/uploads/"+uploadID+"/chunks/0", content, token); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("put chunk status=%d", resp.StatusCode)
	}
	resp, complete := s.do(t, http.MethodPost, "/api/v1/uploads/"+uploadID+"/complete", map[string]any{
		"operationId": "a0000000-0000-4000-8000-" + blobID[24:], "keyScopeId": accountIDOf(t, s, token),
		"keyVersion": 1, "expectedRevision": revision,
	}, token)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("complete upload status=%d body=%v", resp.StatusCode, complete)
	}
}

func getWithHeaders(t *testing.T, s testServer, path, token string, headers map[string]string) (*http.Response, []byte) {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, s.baseURL+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := s.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp, body
}

func TestDownloadSupportsRangeResumption(t *testing.T) {
	s := startTestServer(t)
	token := loginDevice(t, s, "admin", "b0000000-0000-4000-8000-000000000001")["accessToken"].(string)
	file := createNodeOverHTTP(t, s, token, "b0000000-0000-4000-8000-000000000002", "b0000000-0000-4000-8000-000000000003", "FILE", "")
	fileID := file["id"].(string)
	versionID := "b0000000-0000-4000-8000-000000000005"
	uploadOverHTTP(t, s, token, fileID, int64(file["revision"].(float64)), "b0000000-0000-4000-8000-000000000004", versionID, []byte("0123456789"))

	resp, full := getWithHeaders(t, s, "/api/v1/files/"+fileID+"/content", token, nil)
	if resp.StatusCode != http.StatusOK || string(full) != "0123456789" {
		t.Fatalf("full download status=%d body=%q", resp.StatusCode, full)
	}
	etag := resp.Header.Get("ETag")
	if etag != `"`+versionID+`"` || resp.Header.Get("Accept-Ranges") != "bytes" {
		t.Fatalf("download must advertise resumable ranges: etag=%q accept-ranges=%q", etag, resp.Header.Get("Accept-Ranges"))
	}
	resp, tail := getWithHeaders(t, s, "/api/v1/files/"+fileID+"/content", token, map[string]string{"Range": "bytes=4-", "If-Range": etag})
	if resp.StatusCode != http.StatusPartialContent || string(tail) != "456789" || resp.Header.Get("Content-Range") != "bytes 4-9/10" {
		t.Fatalf("ranged download status=%d range=%q body=%q", resp.StatusCode, resp.Header.Get("Content-Range"), tail)
	}
	resp, restarted := getWithHeaders(t, s, "/api/v1/files/"+fileID+"/content", token, map[string]string{"Range": "bytes=4-", "If-Range": `"another-version"`})
	if resp.StatusCode != http.StatusOK || string(restarted) != "0123456789" {
		t.Fatalf("a stale If-Range must restart from zero: status=%d body=%q", resp.StatusCode, restarted)
	}
}

func TestListChildrenPaginatesWithACursor(t *testing.T) {
	s := startTestServer(t)
	token := loginDevice(t, s, "admin", "c0000000-0000-4000-8000-000000000001")["accessToken"].(string)
	want := map[string]bool{}
	for i := 0; i < 3; i++ {
		id := fmt.Sprintf("c0000000-0000-4000-8000-00000000001%d", i)
		createNodeOverHTTP(t, s, token, id, fmt.Sprintf("c0000000-0000-4000-8000-00000000002%d", i), "DIRECTORY", "")
		want[id] = true
	}
	seen := map[string]bool{}
	path := "/api/v1/nodes/children?limit=2"
	for pages := 0; ; pages++ {
		if pages > 3 {
			t.Fatal("pagination did not terminate")
		}
		resp, raw := s.doRaw(t, http.MethodGet, path, nil, token)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("page status=%d body=%s", resp.StatusCode, raw)
		}
		for _, node := range decodeArray(t, raw) {
			id := node["id"].(string)
			if seen[id] {
				t.Fatalf("node %s returned twice", id)
			}
			seen[id] = true
		}
		next := resp.Header.Get("X-Next-After")
		if next == "" {
			break
		}
		path = "/api/v1/nodes/children?limit=2&after=" + url.QueryEscape(next)
	}
	if len(seen) != len(want) {
		t.Fatalf("paged listing returned %v, want %v", seen, want)
	}
	if resp, _ := s.doRaw(t, http.MethodGet, "/api/v1/nodes/children?limit=2&after=not-a-cursor", nil, token); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("malformed cursor status=%d, want 400", resp.StatusCode)
	}
}

func TestNonCanonicalIDsAreRejected(t *testing.T) {
	s := startTestServer(t)
	token := loginDevice(t, s, "admin", "d0000000-0000-4000-8000-000000000001")["accessToken"].(string)
	node := createNodeOverHTTP(t, s, token, "d0000000-0000-4000-8000-0000000000aa", "d0000000-0000-4000-8000-000000000002", "DIRECTORY", "")
	for _, spelling := range []string{"D0000000-0000-4000-8000-0000000000AA", "{" + node["id"].(string) + "}"} {
		if resp, _ := s.get(t, "/api/v1/nodes/"+url.PathEscape(spelling), token); resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("GET %q status=%d, want 400", spelling, resp.StatusCode)
		}
	}
}

func TestShareRecipientLosesAccessToATrashedSubtree(t *testing.T) {
	s := startTestServer(t)
	member, err := s.auth.CreateUser(context.Background(), "member", testPassword)
	if err != nil {
		t.Fatal(err)
	}
	ownerToken := loginDevice(t, s, "admin", "e0000000-0000-4000-8000-000000000001")["accessToken"].(string)
	recipientDevice := "e0000000-0000-4000-8000-000000000002"
	recipientToken := loginDevice(t, s, "member", recipientDevice)["accessToken"].(string)

	shared := createNodeOverHTTP(t, s, ownerToken, "e0000000-0000-4000-8000-000000000010", "e0000000-0000-4000-8000-000000000020", "DIRECTORY", "")
	sub := createNodeOverHTTP(t, s, ownerToken, "e0000000-0000-4000-8000-000000000011", "e0000000-0000-4000-8000-000000000021", "DIRECTORY", shared["id"].(string))
	file := createNodeOverHTTP(t, s, ownerToken, "e0000000-0000-4000-8000-000000000012", "e0000000-0000-4000-8000-000000000022", "FILE", sub["id"].(string))
	shareFolderOverHTTP(t, s, ownerToken, shared["id"].(string), "e0000000-0000-4000-8000-000000000030", member.ID, recipientDevice, "READ")
	fileID := file["id"].(string)
	if resp, _ := s.get(t, "/api/v1/nodes/"+fileID, recipientToken); resp.StatusCode != http.StatusOK {
		t.Fatalf("recipient read of shared descendant status=%d", resp.StatusCode)
	}
	resp, _ := s.do(t, http.MethodDelete, "/api/v1/nodes/"+sub["id"].(string), map[string]any{
		"operationId": "e0000000-0000-4000-8000-000000000040", "expectedRevision": sub["revision"],
	}, ownerToken)
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("trash subfolder status=%d", resp.StatusCode)
	}
	if resp, _ := s.get(t, "/api/v1/nodes/"+fileID, recipientToken); resp.StatusCode != http.StatusForbidden {
		t.Fatalf("recipient read below a trashed folder status=%d, want 403", resp.StatusCode)
	}
	if resp, _ := s.get(t, "/api/v1/nodes/"+fileID, ownerToken); resp.StatusCode != http.StatusOK {
		t.Fatalf("the owner keeps access to their trashed content: status=%d", resp.StatusCode)
	}
}

func TestInternalErrorsShareTheirRequestIDWithTheLog(t *testing.T) {
	s := startTestServer(t)
	token := loginDevice(t, s, "admin", "f0000000-0000-4000-8000-000000000001")["accessToken"].(string)
	file := createNodeOverHTTP(t, s, token, "f0000000-0000-4000-8000-000000000002", "f0000000-0000-4000-8000-000000000003", "FILE", "")
	uploadOverHTTP(t, s, token, file["id"].(string), int64(file["revision"].(float64)), "f0000000-0000-4000-8000-000000000004", "f0000000-0000-4000-8000-000000000005", []byte("ciphertext"))
	if err := removeBlob(s, "f0000000-0000-4000-8000-000000000004"); err != nil {
		t.Fatal(err)
	}
	resp, body := s.get(t, "/api/v1/files/"+file["id"].(string)+"/content", token)
	errorBody, _ := body["error"].(map[string]any)
	if resp.StatusCode != http.StatusInternalServerError || errorBody["requestId"] == "" || errorBody["message"] != "stored ciphertext is missing" {
		t.Fatalf("missing blob status=%d body=%v", resp.StatusCode, body)
	}
}
