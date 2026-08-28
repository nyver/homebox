package httpapi

import (
	"encoding/base64"
	"net/http"
	"strconv"
	"time"
)

type syncChangeResponse struct {
	Revision  int64   `json:"revision"`
	NodeID    *string `json:"nodeId,omitempty"`
	Operation string  `json:"operation"`
	Payload   string  `json:"payload,omitempty"` // base64
	CreatedAt string  `json:"createdAt"`
}

type syncChangesResponse struct {
	Changes   []syncChangeResponse `json:"changes"`
	NextAfter int64                `json:"nextAfter"`
	HasMore   bool                 `json:"hasMore"`
}

// syncChanges serves the paged, decrypt-locally changes feed (spec §19,
// ADR-005). ?after=<revision>&pageSize=<n>; after defaults to 0 (from the
// beginning) and pageSize defaults to the server's configured page size.
func (a *API) syncChanges(w http.ResponseWriter, r *http.Request) {
	after, ok := queryInt64(w, r, "after", 0)
	if !ok {
		return
	}
	pageSize, ok := queryInt(w, r, "pageSize", 0)
	if !ok {
		return
	}
	page, err := a.sync.Changes(r.Context(), requestUserID(r), after, pageSize)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	resp := syncChangesResponse{NextAfter: page.NextAfter, HasMore: page.HasMore, Changes: make([]syncChangeResponse, 0, len(page.Changes))}
	for _, c := range page.Changes {
		entry := syncChangeResponse{Revision: c.Revision, NodeID: c.NodeID, Operation: c.Operation, CreatedAt: c.CreatedAt.Format(time.RFC3339Nano)}
		if len(c.Payload) > 0 {
			entry.Payload = base64.StdEncoding.EncodeToString(c.Payload)
		}
		resp.Changes = append(resp.Changes, entry)
	}
	writeJSON(w, http.StatusOK, resp)
}

func queryInt64(w http.ResponseWriter, r *http.Request, name string, def int64) (int64, bool) {
	raw := r.URL.Query().Get(name)
	if raw == "" {
		return def, true
	}
	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid "+name)
		return 0, false
	}
	return n, true
}

func queryInt(w http.ResponseWriter, r *http.Request, name string, def int) (int, bool) {
	raw := r.URL.Query().Get(name)
	if raw == "" {
		return def, true
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid "+name)
		return 0, false
	}
	return n, true
}
