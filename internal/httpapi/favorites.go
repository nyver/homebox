package httpapi

import (
	"net/http"
	"time"
)

type favoriteResponse struct {
	NodeID    string `json:"nodeId"`
	CreatedAt string `json:"createdAt"`
}

func (a *API) listFavorites(w http.ResponseWriter, r *http.Request) {
	list, err := a.favorites.List(r.Context(), requestUserID(r))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	out := make([]favoriteResponse, 0, len(list))
	for _, favorite := range list {
		out = append(out, favoriteResponse{NodeID: favorite.NodeID, CreatedAt: favorite.CreatedAt.Format(time.RFC3339Nano)})
	}
	writeJSON(w, http.StatusOK, out)
}

func (a *API) addFavorite(w http.ResponseWriter, r *http.Request) {
	nodeID, ok := pathUUID(w, r, "id")
	if !ok {
		return
	}
	if err := a.favorites.Add(r.Context(), requestUserID(r), nodeID); err != nil {
		writeServiceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) removeFavorite(w http.ResponseWriter, r *http.Request) {
	nodeID, ok := pathUUID(w, r, "id")
	if !ok {
		return
	}
	if err := a.favorites.Remove(r.Context(), requestUserID(r), nodeID); err != nil {
		writeServiceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// purgeTrashEntry permanently deletes one of the caller's Trash entries and
// its subtree now instead of after the retention period.
func (a *API) purgeTrashEntry(w http.ResponseWriter, r *http.Request) {
	nodeID, ok := pathUUID(w, r, "id")
	if !ok {
		return
	}
	if err := a.trash.PurgeTrashEntry(r.Context(), requestUserID(r), nodeID); err != nil {
		writeServiceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
