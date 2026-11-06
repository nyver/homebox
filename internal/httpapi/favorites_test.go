package httpapi_test

import (
	"context"
	"net/http"
	"testing"
)

func favoriteIDs(t *testing.T, s testServer, token string) []string {
	t.Helper()
	resp, raw := s.doRaw(t, http.MethodGet, "/api/v1/favorites", nil, token)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("list favorites status=%d", resp.StatusCode)
	}
	var ids []string
	for _, favorite := range decodeArray(t, raw) {
		ids = append(ids, favorite["nodeId"].(string))
	}
	return ids
}

func TestFavoritesFollowVisibilityOfTheirNodes(t *testing.T) {
	s := startTestServer(t)
	member, err := s.auth.CreateUser(context.Background(), "member", testPassword)
	if err != nil {
		t.Fatal(err)
	}
	ownerToken := loginDevice(t, s, "admin", "93000000-0000-4000-8000-000000000001")["accessToken"].(string)
	memberDevice := "93000000-0000-4000-8000-000000000002"
	memberToken := loginDevice(t, s, "member", memberDevice)["accessToken"].(string)
	folder := createNodeOverHTTP(t, s, ownerToken, "93000000-0000-4000-8000-000000000010", "93000000-0000-4000-8000-000000000011", "DIRECTORY", "")
	file := createNodeOverHTTP(t, s, ownerToken, "93000000-0000-4000-8000-000000000012", "93000000-0000-4000-8000-000000000013", "FILE", folder["id"].(string))
	fileID := file["id"].(string)

	for i := 0; i < 2; i++ { // adding twice is idempotent
		if resp, _ := s.do(t, http.MethodPut, "/api/v1/favorites/"+fileID, nil, ownerToken); resp.StatusCode != http.StatusNoContent {
			t.Fatalf("add favorite status=%d", resp.StatusCode)
		}
	}
	if got := favoriteIDs(t, s, ownerToken); len(got) != 1 || got[0] != fileID {
		t.Fatalf("owner favorites=%v", got)
	}
	// A stranger cannot even learn the node exists.
	if resp, _ := s.do(t, http.MethodPut, "/api/v1/favorites/"+fileID, nil, memberToken); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("unshared favorite status=%d, want 404", resp.StatusCode)
	}
	grant := shareFolderOverHTTP(t, s, ownerToken, folder["id"].(string), "93000000-0000-4000-8000-000000000020", member.ID, memberDevice, "READ")
	if resp, _ := s.do(t, http.MethodPut, "/api/v1/favorites/"+fileID, nil, memberToken); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("shared favorite status=%d", resp.StatusCode)
	}
	if got := favoriteIDs(t, s, memberToken); len(got) != 1 {
		t.Fatalf("member favorites=%v", got)
	}
	if resp, _ := s.doRaw(t, http.MethodDelete, "/api/v1/shares/"+grant["id"].(string), nil, ownerToken); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("revoke status=%d", resp.StatusCode)
	}
	if got := favoriteIDs(t, s, memberToken); len(got) != 0 {
		t.Fatalf("favorites after revoke=%v", got)
	}

	// In Trash: hidden; restored: back.
	resp, current := s.get(t, "/api/v1/nodes/"+fileID, ownerToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatal("get file failed")
	}
	if resp, _ := s.do(t, http.MethodDelete, "/api/v1/nodes/"+fileID, map[string]any{"operationId": "93000000-0000-4000-8000-000000000030", "expectedRevision": current["revision"]}, ownerToken); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("delete status=%d", resp.StatusCode)
	}
	if got := favoriteIDs(t, s, ownerToken); len(got) != 0 {
		t.Fatalf("favorites of a trashed node=%v", got)
	}
	if resp, _ := s.do(t, http.MethodPost, "/api/v1/nodes/"+fileID+"/restore", map[string]any{"operationId": "93000000-0000-4000-8000-000000000031"}, ownerToken); resp.StatusCode != http.StatusOK {
		t.Fatalf("restore status=%d", resp.StatusCode)
	}
	if got := favoriteIDs(t, s, ownerToken); len(got) != 1 {
		t.Fatalf("favorites after restore=%v", got)
	}
	if resp, _ := s.do(t, http.MethodDelete, "/api/v1/favorites/"+fileID, nil, ownerToken); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("remove favorite status=%d", resp.StatusCode)
	}
	if got := favoriteIDs(t, s, ownerToken); len(got) != 0 {
		t.Fatalf("favorites after remove=%v", got)
	}
}

func TestPurgeTrashEntryDeletesItsSubtreeNow(t *testing.T) {
	s := startTestServer(t)
	if _, err := s.auth.CreateUser(context.Background(), "member", testPassword); err != nil {
		t.Fatal(err)
	}
	ownerToken := loginDevice(t, s, "admin", "94000000-0000-4000-8000-000000000001")["accessToken"].(string)
	memberToken := loginDevice(t, s, "member", "94000000-0000-4000-8000-000000000002")["accessToken"].(string)
	folder := createNodeOverHTTP(t, s, ownerToken, "94000000-0000-4000-8000-000000000010", "94000000-0000-4000-8000-000000000011", "DIRECTORY", "")
	child := createNodeOverHTTP(t, s, ownerToken, "94000000-0000-4000-8000-000000000012", "94000000-0000-4000-8000-000000000013", "FILE", folder["id"].(string))
	folderID, childID := folder["id"].(string), child["id"].(string)

	// Only a Trash entry can be purged.
	if resp, _ := s.doRaw(t, http.MethodDelete, "/api/v1/trash/"+folderID, nil, ownerToken); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("purge of a live node status=%d, want 404", resp.StatusCode)
	}
	if resp, _ := s.do(t, http.MethodDelete, "/api/v1/nodes/"+folderID, map[string]any{"operationId": "94000000-0000-4000-8000-000000000020", "expectedRevision": folder["revision"]}, ownerToken); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("delete status=%d", resp.StatusCode)
	}
	if resp, _ := s.doRaw(t, http.MethodDelete, "/api/v1/trash/"+folderID, nil, memberToken); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("foreign purge status=%d, want 404", resp.StatusCode)
	}
	if resp, _ := s.doRaw(t, http.MethodDelete, "/api/v1/trash/"+folderID, nil, ownerToken); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("purge status=%d", resp.StatusCode)
	}
	for _, id := range []string{folderID, childID} {
		if resp, _ := s.get(t, "/api/v1/nodes/"+id, ownerToken); resp.StatusCode != http.StatusNotFound {
			t.Fatalf("purged node %s status=%d, want 404", id, resp.StatusCode)
		}
	}
	if resp, raw := s.doRaw(t, http.MethodGet, "/api/v1/trash", nil, ownerToken); resp.StatusCode != http.StatusOK || len(decodeArray(t, raw)) != 0 {
		t.Fatalf("trash after purge status=%d body=%s", resp.StatusCode, raw)
	}
	if resp, _ := s.doRaw(t, http.MethodDelete, "/api/v1/trash/"+folderID, nil, ownerToken); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("repeated purge status=%d, want 404", resp.StatusCode)
	}
	// Other devices learn about it from the sync feed.
	resp, feed := s.get(t, "/api/v1/sync/changes?after=0", ownerToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatal("sync feed failed")
	}
	purges := 0
	for _, raw := range feed["changes"].([]any) {
		if raw.(map[string]any)["operation"] == "PURGE" {
			purges++
		}
	}
	if purges != 2 {
		t.Fatalf("PURGE changes=%d, want 2", purges)
	}
}
