package httpapi

import (
	"encoding/base64"
	"net/http"
	"time"

	"github.com/homebox/homebox/internal/sharing"
)

type shareEnvelopeRequest struct {
	TargetDeviceID string `json:"targetDeviceId"`
	KeyVersion     int    `json:"keyVersion"`
	Ciphertext     string `json:"ciphertext"`
}

type createShareRequest struct {
	OperationID  string                 `json:"operationId"`
	NodeID       string                 `json:"nodeId"`
	TargetUserID string                 `json:"targetUserId"`
	Permission   string                 `json:"permission"`
	Envelopes    []shareEnvelopeRequest `json:"envelopes"`
}

type shareResponse struct {
	ID           string                  `json:"id"`
	NodeID       string                  `json:"nodeId"`
	OwnerUserID  string                  `json:"ownerUserId"`
	TargetUserID string                  `json:"targetUserId"`
	Permission   string                  `json:"permission"`
	CreatedAt    string                  `json:"createdAt"`
	Envelopes    []shareEnvelopeResponse `json:"envelopes"`
}

type shareEnvelopeResponse struct {
	TargetDeviceID string `json:"targetDeviceId"`
	KeyVersion     int    `json:"keyVersion"`
	Ciphertext     string `json:"ciphertext"`
}

func (a *API) createShare(w http.ResponseWriter, r *http.Request) {
	var req createShareRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	envelopes := make([]sharing.DeviceEnvelope, 0, len(req.Envelopes))
	for _, envelope := range req.Envelopes {
		ciphertext, err := base64.StdEncoding.DecodeString(envelope.Ciphertext)
		if err != nil {
			writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "share envelope ciphertext must be base64-encoded")
			return
		}
		envelopes = append(envelopes, sharing.DeviceEnvelope{TargetDeviceID: envelope.TargetDeviceID, KeyVersion: envelope.KeyVersion, Ciphertext: ciphertext})
	}
	share, err := a.shares.CreateReadGrant(r.Context(), sharing.CreateInput{OwnerUserID: requestUserID(r), OwnerDeviceID: requestDeviceID(r), OperationID: req.OperationID, NodeID: req.NodeID, TargetUserID: req.TargetUserID, Permission: req.Permission, Envelopes: envelopes})
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, toShareResponse(share))
}

func (a *API) listIncomingShares(w http.ResponseWriter, r *http.Request) {
	shares, err := a.shares.ListIncoming(r.Context(), requestUserID(r), requestDeviceID(r))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	out := make([]shareResponse, 0, len(shares))
	for _, share := range shares {
		out = append(out, toShareResponse(share))
	}
	writeJSON(w, http.StatusOK, out)
}

func (a *API) listOutgoingShares(w http.ResponseWriter, r *http.Request) {
	shares, err := a.shares.ListOutgoing(r.Context(), requestUserID(r))
	if err != nil {
		writeServiceError(w, err)
		return
	}
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

func toShareResponse(share sharing.Share) shareResponse {
	resp := shareResponse{ID: share.ID, NodeID: share.NodeID, OwnerUserID: share.OwnerUserID, TargetUserID: share.TargetUserID, Permission: share.Permission, CreatedAt: share.CreatedAt.Format(time.RFC3339Nano), Envelopes: make([]shareEnvelopeResponse, 0, len(share.Envelopes))}
	for _, envelope := range share.Envelopes {
		resp.Envelopes = append(resp.Envelopes, shareEnvelopeResponse{TargetDeviceID: envelope.TargetDeviceID, KeyVersion: envelope.KeyVersion, Ciphertext: base64.StdEncoding.EncodeToString(envelope.Ciphertext)})
	}
	return resp
}
