package httpapi

import (
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	"github.com/homebox/homebox/internal/uploads"
)

// maxChunkBodyBytes bounds a single PUT chunk body before it is read.
const maxChunkBodyBytes = uploads.MaxChunkCiphertextSize

type createUploadRequest struct {
	TargetNodeID       string `json:"targetNodeId"`
	FileVersionID      string `json:"fileVersionId"`
	BlobID             string `json:"blobId"`
	ExpectedRevision   *int64 `json:"expectedRevision"`
	ChunkSize          int64  `json:"chunkSize"`
	ChunkCount         int    `json:"chunkCount"`
	MetadataKeyVersion int    `json:"metadataKeyVersion"`
	MetadataCiphertext string `json:"metadataCiphertext"` // base64
	WrappedFileKey     string `json:"wrappedFileKey"`     // base64
	E2eeHeader         string `json:"e2eeHeader"`         // base64
}

type uploadSessionResponse struct {
	ID             string `json:"id"`
	ChunkCount     int    `json:"chunkCount"`
	ReceivedChunks []int  `json:"receivedChunks"`
}

func (a *API) createUpload(w http.ResponseWriter, r *http.Request) {
	var req createUploadRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	metadata, err1 := base64.StdEncoding.DecodeString(req.MetadataCiphertext)
	wrappedKey, err2 := base64.StdEncoding.DecodeString(req.WrappedFileKey)
	header, err3 := base64.StdEncoding.DecodeString(req.E2eeHeader)
	if err1 != nil || err2 != nil || err3 != nil {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "metadataCiphertext, wrappedFileKey, and e2eeHeader must be base64-encoded")
		return
	}
	session, err := a.uploads.Create(r.Context(), uploads.CreateInput{
		UserID: requestUserID(r), DeviceID: requestDeviceID(r), TargetNodeID: req.TargetNodeID,
		FileVersionID: req.FileVersionID, BlobID: req.BlobID, ExpectedRevision: req.ExpectedRevision,
		ChunkSize: req.ChunkSize, ChunkCount: req.ChunkCount, MetadataKeyVersion: req.MetadataKeyVersion,
		MetadataCiphertext: metadata, WrappedFileKey: wrappedKey, E2EEHeader: header,
	})
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, uploadSessionResponse{ID: session.ID, ChunkCount: session.ChunkCount, ReceivedChunks: session.ReceivedChunks})
}

func (a *API) getUpload(w http.ResponseWriter, r *http.Request) {
	id, ok := pathUUID(w, r, "id")
	if !ok {
		return
	}
	session, err := a.uploads.Get(r.Context(), requestUserID(r), requestDeviceID(r), id)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, uploadSessionResponse{ID: session.ID, ChunkCount: session.ChunkCount, ReceivedChunks: session.ReceivedChunks})
}

func (a *API) putUploadChunk(w http.ResponseWriter, r *http.Request) {
	id, ok := pathUUID(w, r, "id")
	if !ok {
		return
	}
	chunkNo, ok := pathInt(w, r, "chunkNo")
	if !ok {
		return
	}
	body := http.MaxBytesReader(w, r.Body, maxChunkBodyBytes)
	ciphertext, err := io.ReadAll(body)
	if err != nil {
		writeError(w, http.StatusBadRequest, "UPLOAD_CHUNK_INVALID", "could not read chunk body")
		return
	}
	if err := a.uploads.PutChunk(r.Context(), requestUserID(r), requestDeviceID(r), id, chunkNo, ciphertext); err != nil {
		writeServiceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type completeUploadRequest struct {
	OperationID           string `json:"operationId"`
	KeyScopeID            string `json:"keyScopeId"`
	KeyVersion            int    `json:"keyVersion"`
	ExpectedRevision      *int64 `json:"expectedRevision"`
	SyncPayloadCiphertext string `json:"syncPayloadCiphertext"` // base64, optional
}

type completeUploadResponse struct {
	BlobID        string `json:"blobId"`
	FileVersionID string `json:"fileVersionId"`
	Revision      int64  `json:"revision"`
}

func (a *API) completeUpload(w http.ResponseWriter, r *http.Request) {
	id, ok := pathUUID(w, r, "id")
	if !ok {
		return
	}
	var req completeUploadRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	var payload []byte
	if req.SyncPayloadCiphertext != "" {
		decoded, err := base64.StdEncoding.DecodeString(req.SyncPayloadCiphertext)
		if err != nil {
			writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "syncPayloadCiphertext must be base64-encoded")
			return
		}
		payload = decoded
	}
	result, err := a.uploads.Complete(r.Context(), id, uploads.CompleteInput{
		UserID: requestUserID(r), DeviceID: requestDeviceID(r), OperationID: req.OperationID,
		KeyScopeID: req.KeyScopeID, KeyVersion: req.KeyVersion, ExpectedRevision: req.ExpectedRevision,
		SyncPayloadCiphertext: payload,
	})
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, completeUploadResponse{BlobID: result.BlobID, FileVersionID: result.FileVersionID, Revision: result.Revision})
}

func (a *API) abortUpload(w http.ResponseWriter, r *http.Request) {
	id, ok := pathUUID(w, r, "id")
	if !ok {
		return
	}
	if err := a.uploads.Abort(r.Context(), requestUserID(r), requestDeviceID(r), id); err != nil {
		writeServiceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// downloadFileContent streams a node's current-version ciphertext blob
// unchanged (spec §10.10/§23) — the server never decrypts it. Authorization
// is the same node-ownership check every other node read uses; a future
// sharing milestone widens that, not this handler.
func (a *API) downloadFileContent(w http.ResponseWriter, r *http.Request) {
	id, ok := pathUUID(w, r, "id")
	if !ok {
		return
	}
	node, err := a.nodes.Get(r.Context(), requestUserID(r), id)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	if node.NodeType != "FILE" || node.CurrentVersionID == nil || node.IsDeleted() {
		writeError(w, http.StatusNotFound, "NOT_FOUND", "node has no file content yet")
		return
	}
	versionID := r.URL.Query().Get("versionId")
	if versionID == "" {
		versionID = *node.CurrentVersionID
	} else if !canonicalUUID(versionID) {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "versionId must be a UUID")
		return
	}
	path, size, err := a.uploads.OpenNodeBlob(r.Context(), id, versionID)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	file, err := os.Open(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			writeInternalError(w, "download ciphertext", "stored ciphertext is missing", err)
			return
		}
		writeInternalError(w, "download ciphertext", "failed to open stored ciphertext", err)
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		writeInternalError(w, "download ciphertext", "failed to open stored ciphertext", err)
		return
	}
	if info.Size() != size {
		writeInternalError(w, "download ciphertext", "stored ciphertext is damaged", fmt.Errorf("blob %s has %d bytes, database records %d", path, info.Size(), size))
		return
	}
	// A file version's ciphertext is immutable, so its ID is a strong ETag.
	// ServeContent then answers Range/If-Range requests, letting a client
	// resume an interrupted large download instead of starting over.
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("ETag", `"`+versionID+`"`)
	http.ServeContent(w, r, "", time.Time{}, file)
}

type fileVersionResponse struct {
	ID                string `json:"id"`
	BlobID            string `json:"blobId"`
	E2eeHeader        string `json:"e2eeHeader"`     // base64
	WrappedFileKey    string `json:"wrappedFileKey"` // base64
	KeyScopeID        string `json:"keyScopeId"`
	KeyVersion        int    `json:"keyVersion"`
	CreatedAt         string `json:"createdAt"`
	CreatedByDeviceID string `json:"createdByDeviceId"`
	Revision          int64  `json:"revision"`
	ChunkCount        int    `json:"chunkCount"`
	CiphertextSize    int64  `json:"ciphertextSize"`
}

// listFileVersions returns every encrypted version descriptor for a node,
// newest first (spec §17.6), so a client can unwrap the File DEK and
// decrypt whichever version it downloads — including restoring an older
// one later, once that endpoint exists.
func (a *API) listFileVersions(w http.ResponseWriter, r *http.Request) {
	id, ok := pathUUID(w, r, "id")
	if !ok {
		return
	}
	node, err := a.nodes.Get(r.Context(), requestUserID(r), id)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	if node.NodeType != "FILE" {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "node is not a file")
		return
	}
	versions, err := a.uploads.ListVersions(r.Context(), id)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	out := make([]fileVersionResponse, 0, len(versions))
	for _, v := range versions {
		out = append(out, fileVersionResponse{
			ID: v.ID, BlobID: v.BlobID, E2eeHeader: base64.StdEncoding.EncodeToString(v.E2EEHeader),
			WrappedFileKey: base64.StdEncoding.EncodeToString(v.WrappedFileKey), KeyScopeID: v.KeyScopeID,
			KeyVersion: v.KeyVersion, CreatedAt: v.CreatedAt.Format(time.RFC3339Nano),
			CreatedByDeviceID: v.CreatedByDeviceID, Revision: v.Revision, ChunkCount: v.ChunkCount,
			CiphertextSize: v.CiphertextSize,
		})
	}
	writeJSON(w, http.StatusOK, out)
}
