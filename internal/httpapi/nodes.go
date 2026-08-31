package httpapi

import (
	"encoding/base64"
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"

	"github.com/homebox/homebox/internal/nodes"
)

type nodeResponse struct {
	ID                 string  `json:"id"`
	ParentID           *string `json:"parentId,omitempty"`
	NodeType           string  `json:"nodeType"`
	MetadataCiphertext string  `json:"metadataCiphertext"` // base64
	MetadataKeyVersion int     `json:"metadataKeyVersion"`
	CurrentVersionID   *string `json:"currentVersionId,omitempty"`
	Revision           int64   `json:"revision"`
	CreatedAt          string  `json:"createdAt"`
	UpdatedAt          string  `json:"updatedAt"`
	DeletedAt          *string `json:"deletedAt,omitempty"`
}

func toNodeResponse(n nodes.Node) nodeResponse {
	resp := nodeResponse{
		ID: n.ID, ParentID: n.ParentID, NodeType: n.NodeType,
		MetadataCiphertext: base64.StdEncoding.EncodeToString(n.MetadataCiphertext),
		MetadataKeyVersion: n.MetadataKeyVersion, CurrentVersionID: n.CurrentVersionID, Revision: n.Revision,
		CreatedAt: n.CreatedAt.Format(time.RFC3339Nano), UpdatedAt: n.UpdatedAt.Format(time.RFC3339Nano),
	}
	if n.DeletedAt != nil {
		deletedAt := n.DeletedAt.Format(time.RFC3339Nano)
		resp.DeletedAt = &deletedAt
	}
	return resp
}

type createNodeRequest struct {
	ID                 string  `json:"id"`
	OperationID        string  `json:"operationId"`
	ParentID           *string `json:"parentId"`
	NodeType           string  `json:"nodeType"`
	MetadataCiphertext string  `json:"metadataCiphertext"` // base64
	MetadataKeyVersion int     `json:"metadataKeyVersion"`
}

func (a *API) createNode(w http.ResponseWriter, r *http.Request) {
	var req createNodeRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	metadata, err := base64.StdEncoding.DecodeString(req.MetadataCiphertext)
	if err != nil {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "metadataCiphertext must be base64-encoded")
		return
	}
	node, err := a.nodes.Create(r.Context(), nodes.CreateInput{
		ID: req.ID, OwnerID: requestUserID(r), DeviceID: requestDeviceID(r), OperationID: req.OperationID,
		ParentID: req.ParentID, NodeType: req.NodeType, MetadataCiphertext: metadata, MetadataKeyVersion: req.MetadataKeyVersion,
	})
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, toNodeResponse(node))
}

func (a *API) getNode(w http.ResponseWriter, r *http.Request) {
	id, ok := pathUUID(w, r, "id")
	if !ok {
		return
	}
	node, err := a.nodes.Get(r.Context(), requestUserID(r), id)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toNodeResponse(node))
}

// listChildren lists a single level of the tree: the caller's root nodes
// when parentId is omitted, or a specific directory's children otherwise.
// A dedicated path segment (rather than /api/v1/nodes/{id}/children) avoids
// needing a sentinel "root" ID for the no-parent case.
func (a *API) listChildren(w http.ResponseWriter, r *http.Request) {
	var parentID *string
	if raw := r.URL.Query().Get("parentId"); raw != "" {
		if _, err := uuid.Parse(raw); err != nil {
			writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid parentId")
			return
		}
		parentID = &raw
	}
	ownedOnly := r.URL.Query().Get("ownedOnly") == "true"
	if ownedOnly && parentID != nil {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "ownedOnly is valid only for root nodes")
		return
	}
	var children []nodes.Node
	var err error
	if ownedOnly {
		children, err = a.nodes.ListOwnedRoots(r.Context(), requestUserID(r))
	} else {
		children, err = a.nodes.ListChildren(r.Context(), requestUserID(r), parentID)
	}
	if err != nil {
		writeServiceError(w, err)
		return
	}
	out := make([]nodeResponse, 0, len(children))
	for _, n := range children {
		out = append(out, toNodeResponse(n))
	}
	writeJSON(w, http.StatusOK, out)
}

func (a *API) listTrash(w http.ResponseWriter, r *http.Request) {
	trashed, err := a.nodes.ListTrash(r.Context(), requestUserID(r))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	out := make([]nodeResponse, 0, len(trashed))
	for _, n := range trashed {
		out = append(out, toNodeResponse(n))
	}
	writeJSON(w, http.StatusOK, out)
}

type updateNodeRequest struct {
	OperationID        string  `json:"operationId"`
	ExpectedRevision   int64   `json:"expectedRevision"`
	MetadataCiphertext *string `json:"metadataCiphertext"` // base64; omitted/null = unchanged
	MetadataKeyVersion int     `json:"metadataKeyVersion"`
	MoveParent         bool    `json:"moveParent"`
	ParentID           *string `json:"parentId"`
}

func (a *API) updateNode(w http.ResponseWriter, r *http.Request) {
	id, ok := pathUUID(w, r, "id")
	if !ok {
		return
	}
	var req updateNodeRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	var metadata []byte
	if req.MetadataCiphertext != nil {
		decoded, err := base64.StdEncoding.DecodeString(*req.MetadataCiphertext)
		if err != nil {
			writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "metadataCiphertext must be base64-encoded")
			return
		}
		metadata = decoded
	}
	node, err := a.nodes.Update(r.Context(), nodes.UpdateInput{
		UserID: requestUserID(r), DeviceID: requestDeviceID(r), OperationID: req.OperationID, NodeID: id,
		ExpectedRevision: req.ExpectedRevision, MetadataCiphertext: metadata, MetadataKeyVersion: req.MetadataKeyVersion,
		MoveParent: req.MoveParent, ParentID: req.ParentID,
	})
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toNodeResponse(node))
}

type deleteOrRestoreRequest struct {
	OperationID      string `json:"operationId"`
	ExpectedRevision int64  `json:"expectedRevision"`
}

func (a *API) deleteNode(w http.ResponseWriter, r *http.Request) {
	id, ok := pathUUID(w, r, "id")
	if !ok {
		return
	}
	var req deleteOrRestoreRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	if err := a.nodes.Delete(r.Context(), requestUserID(r), requestDeviceID(r), id, req.OperationID, req.ExpectedRevision); err != nil {
		writeServiceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) restoreNode(w http.ResponseWriter, r *http.Request) {
	id, ok := pathUUID(w, r, "id")
	if !ok {
		return
	}
	var req deleteOrRestoreRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	node, err := a.nodes.Restore(r.Context(), requestUserID(r), requestDeviceID(r), id, req.OperationID)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toNodeResponse(node))
}

func pathUUID(w http.ResponseWriter, r *http.Request, name string) (string, bool) {
	id := r.PathValue(name)
	if _, err := uuid.Parse(id); err != nil {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid "+name)
		return "", false
	}
	return id, true
}

// pathInt parses a non-negative integer path segment (chunk numbers).
func pathInt(w http.ResponseWriter, r *http.Request, name string) (int, bool) {
	raw := r.PathValue(name)
	n, err := strconv.Atoi(raw)
	if err != nil || n < 0 {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid "+name)
		return 0, false
	}
	return n, true
}
