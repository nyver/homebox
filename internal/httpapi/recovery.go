package httpapi

import (
	"encoding/base64"
	"net/http"
	"time"
)

type recoveryBundleRequest struct {
	Bundle                   string `json:"bundle"`                   // base64
	AccountIdentityPublicKey string `json:"accountIdentityPublicKey"` // base64
	Signature                string `json:"signature"`                // base64
}

type recoveryBundleResponse struct {
	Bundle            string `json:"bundle"` // base64
	UpdatedAt         string `json:"updatedAt"`
	UpdatedByDeviceID string `json:"updatedByDeviceId"`
}

// getRecoveryBundle returns the caller's own opaque recovery bundle. Any
// signed-in device of the account may read it: opening it still requires
// the Recovery Secret, which the server never has.
func (a *API) getRecoveryBundle(w http.ResponseWriter, r *http.Request) {
	bundle, err := a.recovery.Get(r.Context(), requestUserID(r))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, recoveryBundleResponse{
		Bundle:            base64.StdEncoding.EncodeToString(bundle.Bundle),
		UpdatedAt:         bundle.UpdatedAt.Format(time.RFC3339Nano),
		UpdatedByDeviceID: bundle.UpdatedByDeviceID,
	})
}

// putRecoveryBundle stores or replaces the caller's recovery bundle. The
// recovery service checks the account-identity signature before accepting it.
func (a *API) putRecoveryBundle(w http.ResponseWriter, r *http.Request) {
	var req recoveryBundleRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	bundle, err := base64.StdEncoding.DecodeString(req.Bundle)
	if err != nil {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "bundle must be base64-encoded")
		return
	}
	publicKey, err := base64.StdEncoding.DecodeString(req.AccountIdentityPublicKey)
	if err != nil {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "accountIdentityPublicKey must be base64-encoded")
		return
	}
	signature, err := base64.StdEncoding.DecodeString(req.Signature)
	if err != nil {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "signature must be base64-encoded")
		return
	}
	if err := a.recovery.Put(r.Context(), requestUserID(r), requestDeviceID(r), bundle, publicKey, signature); err != nil {
		writeServiceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
