package httpapi

import (
	"encoding/base64"
	"net/http"
	"time"

	"github.com/homebox/homebox/internal/sharing"
)

type shareEnvelopeRequest struct {
	TargetDeviceID         string `json:"targetDeviceId"`
	KeyVersion             int    `json:"keyVersion"`
	Ciphertext             string `json:"ciphertext"`
	OwnerIdentityPublicKey string `json:"ownerIdentityPublicKey"`
	OwnerSignature         string `json:"ownerSignature"`
}

type createShareRequest struct {
	OperationID  string                 `json:"operationId"`
	NodeID       string                 `json:"nodeId"`
	TargetUserID string                 `json:"targetUserId"`
	Permission   string                 `json:"permission"`
	Envelopes    []shareEnvelopeRequest `json:"envelopes"`
}

type addShareEnvelopesRequest struct {
	Envelopes []shareEnvelopeRequest `json:"envelopes"`
}

type shareResponse struct {
	ID             string                  `json:"id"`
	NodeID         string                  `json:"nodeId"`
	OwnerUserID    string                  `json:"ownerUserId"`
	OwnerUsername  string                  `json:"ownerUsername"`
	TargetUserID   string                  `json:"targetUserId"`
	TargetUsername string                  `json:"targetUsername"`
	Permission     string                  `json:"permission"`
	CreatedAt      string                  `json:"createdAt"`
	Envelopes      []shareEnvelopeResponse `json:"envelopes"`
}

type shareEnvelopeResponse struct {
	TargetDeviceID         string `json:"targetDeviceId"`
	KeyVersion             int    `json:"keyVersion"`
	Ciphertext             string `json:"ciphertext"`
	OwnerIdentityPublicKey string `json:"ownerIdentityPublicKey,omitempty"`
	OwnerSignature         string `json:"ownerSignature,omitempty"`
}

type createFolderKeyRequest struct {
	KeyVersion    int    `json:"keyVersion"`
	OwnerEnvelope string `json:"ownerEnvelope"`
}

type folderKeyResponse struct {
	FolderID      string `json:"folderId"`
	KeyVersion    int    `json:"keyVersion"`
	OwnerEnvelope string `json:"ownerEnvelope"`
	CreatedAt     string `json:"createdAt"`
}

// decodeShareEnvelopes converts request envelopes, writing a 400 response
// and returning false on malformed base64.
func decodeShareEnvelopes(w http.ResponseWriter, in []shareEnvelopeRequest) ([]sharing.DeviceEnvelope, bool) {
	envelopes := make([]sharing.DeviceEnvelope, 0, len(in))
	for _, envelope := range in {
		ciphertext, err1 := base64.StdEncoding.DecodeString(envelope.Ciphertext)
		identity, err2 := base64.StdEncoding.DecodeString(envelope.OwnerIdentityPublicKey)
		signature, err3 := base64.StdEncoding.DecodeString(envelope.OwnerSignature)
		if err1 != nil || err2 != nil || err3 != nil {
			writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "share envelope fields must be base64-encoded")
			return nil, false
		}
		envelopes = append(envelopes, sharing.DeviceEnvelope{
			TargetDeviceID: envelope.TargetDeviceID, KeyVersion: envelope.KeyVersion, Ciphertext: ciphertext,
			OwnerIdentityPublicKey: identity, OwnerSignature: signature,
		})
	}
	return envelopes, true
}

func (a *API) createShare(w http.ResponseWriter, r *http.Request) {
	var req createShareRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	envelopes, ok := decodeShareEnvelopes(w, req.Envelopes)
	if !ok {
		return
	}
	share, err := a.shares.CreateGrant(r.Context(), sharing.CreateInput{OwnerUserID: requestUserID(r), OwnerDeviceID: requestDeviceID(r), OperationID: req.OperationID, NodeID: req.NodeID, TargetUserID: req.TargetUserID, Permission: req.Permission, Envelopes: envelopes})
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, toShareResponse(share))
}

func (a *API) addShareEnvelopes(w http.ResponseWriter, r *http.Request) {
	shareID, ok := pathUUID(w, r, "id")
	if !ok {
		return
	}
	var req addShareEnvelopesRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	envelopes, ok := decodeShareEnvelopes(w, req.Envelopes)
	if !ok {
		return
	}
	share, err := a.shares.AddEnvelopes(r.Context(), requestUserID(r), requestDeviceID(r), shareID, envelopes)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toShareResponse(share))
}

func (a *API) listIncomingShares(w http.ResponseWriter, r *http.Request) {
	shares, err := a.shares.ListIncoming(r.Context(), requestUserID(r), requestDeviceID(r))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeShares(w, shares)
}

func (a *API) listOutgoingShares(w http.ResponseWriter, r *http.Request) {
	shares, err := a.shares.ListOutgoing(r.Context(), requestUserID(r))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeShares(w, shares)
}

func writeShares(w http.ResponseWriter, shares []sharing.Share) {
	out := make([]shareResponse, 0, len(shares))
	for _, share := range shares {
		out = append(out, toShareResponse(share))
	}
	writeJSON(w, http.StatusOK, out)
}

func (a *API) revokeShare(w http.ResponseWriter, r *http.Request) {
	shareID, ok := pathUUID(w, r, "id")
	if !ok {
		return
	}
	if err := a.shares.Revoke(r.Context(), requestUserID(r), requestDeviceID(r), shareID); err != nil {
		writeServiceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// createFolderKey stores the next version of a folder's key, wrapped by
// the owner's own Vault Key (ADR-023). The server cannot open it.
func (a *API) createFolderKey(w http.ResponseWriter, r *http.Request) {
	folderID, ok := pathUUID(w, r, "id")
	if !ok {
		return
	}
	var req createFolderKeyRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	envelope, err := base64.StdEncoding.DecodeString(req.OwnerEnvelope)
	if err != nil {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "ownerEnvelope must be base64-encoded")
		return
	}
	key, err := a.shares.CreateFolderKey(r.Context(), requestUserID(r), requestDeviceID(r), folderID, req.KeyVersion, envelope)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, toFolderKeyResponse(key))
}

func (a *API) listFolderKeys(w http.ResponseWriter, r *http.Request) {
	keys, err := a.shares.ListFolderKeys(r.Context(), requestUserID(r))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	out := make([]folderKeyResponse, 0, len(keys))
	for _, key := range keys {
		out = append(out, toFolderKeyResponse(key))
	}
	writeJSON(w, http.StatusOK, out)
}

func toFolderKeyResponse(key sharing.FolderKey) folderKeyResponse {
	return folderKeyResponse{FolderID: key.FolderID, KeyVersion: key.KeyVersion, OwnerEnvelope: base64.StdEncoding.EncodeToString(key.OwnerEnvelope), CreatedAt: key.CreatedAt.Format(time.RFC3339Nano)}
}

func toShareResponse(share sharing.Share) shareResponse {
	resp := shareResponse{ID: share.ID, NodeID: share.NodeID, OwnerUserID: share.OwnerUserID, OwnerUsername: share.OwnerUsername,
		TargetUserID: share.TargetUserID, TargetUsername: share.TargetUsername, Permission: share.Permission,
		CreatedAt: share.CreatedAt.Format(time.RFC3339Nano), Envelopes: make([]shareEnvelopeResponse, 0, len(share.Envelopes))}
	for _, envelope := range share.Envelopes {
		resp.Envelopes = append(resp.Envelopes, shareEnvelopeResponse{
			TargetDeviceID: envelope.TargetDeviceID, KeyVersion: envelope.KeyVersion, Ciphertext: base64.StdEncoding.EncodeToString(envelope.Ciphertext),
			OwnerIdentityPublicKey: base64.StdEncoding.EncodeToString(envelope.OwnerIdentityPublicKey),
			OwnerSignature:         base64.StdEncoding.EncodeToString(envelope.OwnerSignature),
		})
	}
	return resp
}
