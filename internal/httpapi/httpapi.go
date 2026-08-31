// Package httpapi implements the authenticated business API surface
// described in specification §17: auth, device registration, and
// key-envelope exchange. It only ever handles opaque identifiers and
// ciphertext/base64 blobs from clients — it has no dependency on, and
// cannot reach, any client-side E2EE decryption code (spec
// §35.13/§38.3A's architectural separation requirement).
package httpapi

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/homebox/homebox/internal/apierror"
	"github.com/homebox/homebox/internal/auth"
	"github.com/homebox/homebox/internal/nodes"
	"github.com/homebox/homebox/internal/provisioning"
	"github.com/homebox/homebox/internal/sharing"
	"github.com/homebox/homebox/internal/sync"
	"github.com/homebox/homebox/internal/uploads"
)

// maxRequestBodyBytes is generous for JSON control-plane payloads. File
// bytes never transit this API (see the roadmap's upload service wiring).
const maxRequestBodyBytes = 1 << 20

type API struct {
	auth         *auth.Service
	provisioning *provisioning.Service
	nodes        *nodes.Service
	sync         *sync.Service
	uploads      *uploads.Service
	shares       *sharing.Service
}

func New(authService *auth.Service, provisioningService *provisioning.Service, nodesService *nodes.Service, syncService *sync.Service, uploadsService *uploads.Service, sharingService *sharing.Service) http.Handler {
	api := &API{auth: authService, provisioning: provisioningService, nodes: nodesService, sync: syncService, uploads: uploadsService, shares: sharingService}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/auth/login", api.login)
	mux.HandleFunc("POST /api/v1/auth/refresh", api.refresh)
	mux.HandleFunc("POST /api/v1/auth/logout", api.logout)
	mux.Handle("GET /api/v1/users/me", api.authenticated(api.getMe))
	mux.Handle("GET /api/v1/users/{id}/share-devices", api.authenticated(api.listShareDevices))
	mux.Handle("POST /api/v1/shares", api.authenticated(api.createShare))
	mux.Handle("GET /api/v1/shares/incoming", api.authenticated(api.listIncomingShares))
	mux.Handle("GET /api/v1/shares/outgoing", api.authenticated(api.listOutgoingShares))
	mux.Handle("DELETE /api/v1/shares/{id}", api.authenticated(api.revokeShare))
	mux.Handle("GET /api/v1/devices", api.authenticated(api.listDevices))
	mux.Handle("DELETE /api/v1/devices/{id}", api.authenticated(api.revokeDevice))
	mux.Handle("POST /api/v1/devices/{id}/key-envelope", api.authenticated(api.uploadKeyEnvelope))
	mux.Handle("GET /api/v1/devices/{id}/key-envelope", api.authenticated(api.downloadKeyEnvelope))

	mux.Handle("POST /api/v1/nodes", api.authenticated(api.createNode))
	mux.Handle("GET /api/v1/nodes/children", api.authenticated(api.listChildren))
	mux.Handle("GET /api/v1/nodes/{id}", api.authenticated(api.getNode))
	mux.Handle("PATCH /api/v1/nodes/{id}", api.authenticated(api.updateNode))
	mux.Handle("DELETE /api/v1/nodes/{id}", api.authenticated(api.deleteNode))
	mux.Handle("POST /api/v1/nodes/{id}/restore", api.authenticated(api.restoreNode))
	mux.Handle("GET /api/v1/trash", api.authenticated(api.listTrash))

	mux.Handle("GET /api/v1/sync/changes", api.authenticated(api.syncChanges))

	mux.Handle("POST /api/v1/uploads", api.authenticated(api.createUpload))
	mux.Handle("GET /api/v1/uploads/{id}", api.authenticated(api.getUpload))
	mux.Handle("PUT /api/v1/uploads/{id}/chunks/{chunkNo}", api.authenticated(api.putUploadChunk))
	mux.Handle("POST /api/v1/uploads/{id}/complete", api.authenticated(api.completeUpload))
	mux.Handle("DELETE /api/v1/uploads/{id}", api.authenticated(api.abortUpload))

	mux.Handle("GET /api/v1/files/{id}/content", api.authenticated(api.downloadFileContent))
	mux.Handle("GET /api/v1/files/{id}/versions", api.authenticated(api.listFileVersions))
	return mux
}

type contextKey int

const (
	ctxUserIDKey contextKey = iota
	ctxDeviceIDKey
)

func (a *API) authenticated(next http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := bearerToken(r)
		if token == "" {
			writeError(w, http.StatusUnauthorized, "AUTH_TOKEN_EXPIRED", "missing or malformed Authorization header")
			return
		}
		userID, deviceID, err := a.auth.Authenticate(r.Context(), token)
		if err != nil {
			writeServiceError(w, err)
			return
		}
		ctx := context.WithValue(r.Context(), ctxUserIDKey, userID)
		ctx = context.WithValue(ctx, ctxDeviceIDKey, deviceID)
		next(w, r.WithContext(ctx))
	})
}

func bearerToken(r *http.Request) string {
	const prefix = "Bearer "
	header := r.Header.Get("Authorization")
	if !strings.HasPrefix(header, prefix) {
		return ""
	}
	return strings.TrimPrefix(header, prefix)
}

func requestUserID(r *http.Request) string   { return r.Context().Value(ctxUserIDKey).(string) }
func requestDeviceID(r *http.Request) string { return r.Context().Value(ctxDeviceIDKey).(string) }

// --- auth ---

type deviceRegistrationBody struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Platform   string `json:"platform"`
	PublicKey  string `json:"publicKey"` // base64
	KeyVersion int    `json:"keyVersion"`
}

type loginRequest struct {
	Username string                 `json:"username"`
	Password string                 `json:"password"`
	Device   deviceRegistrationBody `json:"device"`
}

type sessionResponse struct {
	User struct {
		ID       string `json:"id"`
		Username string `json:"username"`
		Role     string `json:"role"`
	} `json:"user"`
	Device struct {
		ID       string `json:"id"`
		Platform string `json:"platform"`
	} `json:"device"`
	AccessToken           string `json:"accessToken"`
	AccessTokenExpiresAt  string `json:"accessTokenExpiresAt"`
	RefreshToken          string `json:"refreshToken"`
	RefreshTokenExpiresAt string `json:"refreshTokenExpiresAt"`
}

func (a *API) login(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	publicKey, err := base64.StdEncoding.DecodeString(req.Device.PublicKey)
	if err != nil {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "device.publicKey must be base64-encoded")
		return
	}
	session, err := a.auth.Login(r.Context(), req.Username, req.Password, auth.DeviceRegistration{
		ID: req.Device.ID, Name: req.Device.Name, Platform: req.Device.Platform,
		PublicKey: publicKey, KeyVersion: req.Device.KeyVersion,
	})
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toSessionResponse(session))
}

type refreshTokenRequest struct {
	RefreshToken string `json:"refreshToken"`
}

func (a *API) refresh(w http.ResponseWriter, r *http.Request) {
	var req refreshTokenRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	session, err := a.auth.Refresh(r.Context(), req.RefreshToken)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toSessionResponse(session))
}

func (a *API) logout(w http.ResponseWriter, r *http.Request) {
	var req refreshTokenRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	if err := a.auth.Logout(r.Context(), req.RefreshToken); err != nil {
		log.Printf("logout: %v", err)
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to logout")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) getMe(w http.ResponseWriter, r *http.Request) {
	user, err := a.auth.GetUser(r.Context(), requestUserID(r))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"id": user.ID, "username": user.Username, "role": user.Role})
}

// listShareDevices exposes recipient public keys only after the caller has
// obtained that person's opaque user ID through a deliberate family invite.
// It contains no private key material or plaintext vault metadata.
func (a *API) listShareDevices(w http.ResponseWriter, r *http.Request) {
	userID, ok := pathUUID(w, r, "id")
	if !ok {
		return
	}
	devices, err := a.auth.ListShareableDevices(r.Context(), userID)
	if err != nil {
		log.Printf("list share devices: %v", err)
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to list recipient devices")
		return
	}
	if len(devices) == 0 {
		writeError(w, http.StatusNotFound, "NOT_FOUND", "no active recipient device found")
		return
	}
	out := make([]shareDeviceResponse, 0, len(devices))
	for _, device := range devices {
		out = append(out, shareDeviceResponse{
			ID: device.ID, Platform: device.Platform, PublicKey: base64.StdEncoding.EncodeToString(device.PublicKey), KeyVersion: device.KeyVersion,
		})
	}
	writeJSON(w, http.StatusOK, out)
}

// --- devices ---

type deviceResponse struct {
	ID          string  `json:"id"`
	Name        string  `json:"name"`
	Platform    string  `json:"platform"`
	PublicKey   string  `json:"publicKey"`
	KeyVersion  int     `json:"keyVersion"`
	CreatedAt   string  `json:"createdAt"`
	LastSeenAt  string  `json:"lastSeenAt"`
	LastSyncAt  *string `json:"lastSyncAt,omitempty"`
	RevokedAt   *string `json:"revokedAt,omitempty"`
	HasVaultKey bool    `json:"hasVaultKey"`
}

type shareDeviceResponse struct {
	ID         string `json:"id"`
	Platform   string `json:"platform"`
	PublicKey  string `json:"publicKey"`
	KeyVersion int    `json:"keyVersion"`
}

func toDeviceResponse(d auth.Device) deviceResponse {
	resp := deviceResponse{
		ID: d.ID, Name: d.Name, Platform: d.Platform, KeyVersion: d.KeyVersion,
		PublicKey:  base64.StdEncoding.EncodeToString(d.PublicKey),
		CreatedAt:  d.CreatedAt.Format(time.RFC3339Nano),
		LastSeenAt: d.LastSeenAt.Format(time.RFC3339Nano),
	}
	if d.LastSyncAt != nil {
		lastSyncAt := d.LastSyncAt.Format(time.RFC3339Nano)
		resp.LastSyncAt = &lastSyncAt
	}
	if d.RevokedAt != nil {
		revoked := d.RevokedAt.Format(time.RFC3339Nano)
		resp.RevokedAt = &revoked
	}
	return resp
}

func (a *API) listDevices(w http.ResponseWriter, r *http.Request) {
	userID := requestUserID(r)
	devices, err := a.auth.ListDevices(r.Context(), userID)
	if err != nil {
		log.Printf("list devices: %v", err)
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to list devices")
		return
	}
	approved, err := a.provisioning.ActiveEnvelopeDeviceIDs(r.Context(), userID)
	if err != nil {
		log.Printf("list devices: %v", err)
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to list devices")
		return
	}
	out := make([]deviceResponse, 0, len(devices))
	for _, d := range devices {
		resp := toDeviceResponse(d)
		resp.HasVaultKey = approved[d.ID]
		out = append(out, resp)
	}
	writeJSON(w, http.StatusOK, out)
}

func (a *API) revokeDevice(w http.ResponseWriter, r *http.Request) {
	targetDeviceID, ok := pathDeviceID(w, r)
	if !ok {
		return
	}
	if err := a.auth.RevokeDevice(r.Context(), requestUserID(r), targetDeviceID); err != nil {
		writeServiceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// --- key envelopes ---

type uploadEnvelopeRequest struct {
	VaultID    string `json:"vaultId"`
	KeyVersion int    `json:"keyVersion"`
	Ciphertext string `json:"ciphertext"` // base64
}

// uploadKeyEnvelope lets any of the caller's own active devices deliver a
// provisioning envelope to another of their own devices. Sharing an
// envelope across different user accounts is part of Family Vault sharing
// (spec §28) and is out of scope until that milestone.
func (a *API) uploadKeyEnvelope(w http.ResponseWriter, r *http.Request) {
	targetDeviceID, ok := pathDeviceID(w, r)
	if !ok {
		return
	}
	var req uploadEnvelopeRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	ciphertext, err := base64.StdEncoding.DecodeString(req.Ciphertext)
	if err != nil {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "ciphertext must be base64-encoded")
		return
	}
	userID := requestUserID(r)
	target, err := a.auth.GetDevice(r.Context(), userID, targetDeviceID)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	if target.RevokedAt != nil {
		writeServiceError(w, auth.ErrDeviceRevoked)
		return
	}
	envelope, err := a.provisioning.Upload(r.Context(), req.VaultID, userID, targetDeviceID, req.KeyVersion, ciphertext)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": envelope.ID})
}

// downloadKeyEnvelope only ever serves a device its own envelope: the
// specification's provisioning flow requires the *target* device to
// retrieve and locally unwrap it (§16.2), not any other device on the
// account.
func (a *API) downloadKeyEnvelope(w http.ResponseWriter, r *http.Request) {
	targetDeviceID, ok := pathDeviceID(w, r)
	if !ok {
		return
	}
	if targetDeviceID != requestDeviceID(r) {
		writeError(w, http.StatusForbidden, "FORBIDDEN", "a device may only download its own key envelope")
		return
	}
	envelope, err := a.provisioning.Latest(r.Context(), targetDeviceID)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id": envelope.ID, "vaultId": envelope.VaultID, "keyVersion": envelope.KeyVersion,
		"ciphertext": base64.StdEncoding.EncodeToString(envelope.Ciphertext),
	})
}

func pathDeviceID(w http.ResponseWriter, r *http.Request) (string, bool) {
	id := r.PathValue("id")
	if _, err := uuid.Parse(id); err != nil {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid device id")
		return "", false
	}
	return id, true
}

// --- wire helpers ---

func toSessionResponse(s auth.Session) sessionResponse {
	var resp sessionResponse
	resp.User.ID, resp.User.Username, resp.User.Role = s.User.ID, s.User.Username, s.User.Role
	resp.Device.ID, resp.Device.Platform = s.Device.ID, s.Device.Platform
	resp.AccessToken = s.AccessToken
	resp.AccessTokenExpiresAt = s.AccessTokenExpiresAt.Format(time.RFC3339Nano)
	resp.RefreshToken = s.RefreshToken
	resp.RefreshTokenExpiresAt = s.RefreshTokenExpiresAt.Format(time.RFC3339Nano)
	return resp
}

func decodeJSON(w http.ResponseWriter, r *http.Request, dest any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxRequestBodyBytes)
	if err := json.NewDecoder(r.Body).Decode(dest); err != nil {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "malformed JSON request body")
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

type errorResponse struct {
	Error struct {
		Code      string `json:"code"`
		Message   string `json:"message"`
		RequestID string `json:"requestId"`
	} `json:"error"`
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	var body errorResponse
	body.Error.Code = code
	body.Error.Message = message
	body.Error.RequestID = uuid.NewString()
	writeJSON(w, status, body)
}

// writeServiceError maps every domain service's sentinel errors to the spec
// §18 error codes. An *apierror.Validation is always safe to show verbatim
// (domain services only ever construct one for malformed input, checked
// before any database access — see internal/apierror); anything else that
// isn't a recognized sentinel is treated as an internal error, logged
// server-side, and never shown to the client, so a raw database/driver
// error message can never leak through this API.
func writeServiceError(w http.ResponseWriter, err error) {
	var validation *apierror.Validation
	switch {
	case errors.As(err, &validation):
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", validation.Message)

	case errors.Is(err, auth.ErrInvalidCredentials):
		writeError(w, http.StatusUnauthorized, "AUTH_INVALID_CREDENTIALS", "invalid username or password")
	case errors.Is(err, auth.ErrAccountDisabled):
		writeError(w, http.StatusForbidden, "FORBIDDEN", "account is disabled")
	case errors.Is(err, auth.ErrDeviceRevoked):
		writeError(w, http.StatusForbidden, "AUTH_DEVICE_REVOKED", "device has been revoked")
	case errors.Is(err, auth.ErrDeviceConflict):
		writeError(w, http.StatusConflict, "VALIDATION_ERROR", "device id is already registered to a different account or key")
	case errors.Is(err, auth.ErrTokenInvalid):
		writeError(w, http.StatusUnauthorized, "AUTH_TOKEN_EXPIRED", "token is invalid, expired, or revoked")
	case errors.Is(err, auth.ErrNotFound):
		writeError(w, http.StatusNotFound, "NOT_FOUND", "not found")
	case errors.Is(err, auth.ErrRateLimited):
		writeError(w, http.StatusTooManyRequests, "AUTH_RATE_LIMITED", "too many failed login attempts; try again shortly")

	case errors.Is(err, nodes.ErrNotFound):
		writeError(w, http.StatusNotFound, "NOT_FOUND", "node not found")
	case errors.Is(err, nodes.ErrForbidden):
		writeError(w, http.StatusForbidden, "FORBIDDEN", "node does not belong to this account")
	case errors.Is(err, nodes.ErrRevisionConflict):
		writeError(w, http.StatusConflict, "REVISION_CONFLICT", "node revision conflict")
	case errors.Is(err, nodes.ErrInvalidParent):
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "parent must be an existing, non-deleted directory owned by this account")

	case errors.Is(err, uploads.ErrNotFound):
		writeError(w, http.StatusNotFound, "UPLOAD_NOT_FOUND", "upload session not found")
	case errors.Is(err, uploads.ErrForbidden):
		writeError(w, http.StatusForbidden, "FORBIDDEN", "upload session does not belong to this device")
	case errors.Is(err, uploads.ErrInvalidState):
		writeError(w, http.StatusConflict, "UPLOAD_EXPIRED", "upload session is not open")
	case errors.Is(err, uploads.ErrChunkConflict):
		writeError(w, http.StatusConflict, "UPLOAD_CHUNK_INVALID", "chunk already exists with a different ciphertext digest")
	case errors.Is(err, uploads.ErrMissingChunks):
		writeError(w, http.StatusBadRequest, "UPLOAD_CHUNK_INVALID", "upload has missing ciphertext chunks")
	case errors.Is(err, uploads.ErrRevisionConflict):
		writeError(w, http.StatusConflict, "REVISION_CONFLICT", "node revision conflict")
	case errors.Is(err, uploads.ErrTargetNodeMissing):
		writeError(w, http.StatusNotFound, "NOT_FOUND", "target file node not found")

	case errors.Is(err, sync.ErrInvalidCursor):
		writeError(w, http.StatusBadRequest, "SYNC_CURSOR_INVALID", "sync cursor is invalid")

	case errors.Is(err, provisioning.ErrNotFound):
		writeError(w, http.StatusNotFound, "NOT_FOUND", "no key envelope is available yet")

	case errors.Is(err, sharing.ErrNotFound), errors.Is(err, sharing.ErrTargetNotFound):
		writeError(w, http.StatusNotFound, "NOT_FOUND", "share or recipient was not found")
	case errors.Is(err, sharing.ErrForbidden):
		writeError(w, http.StatusForbidden, "FORBIDDEN", "share is not owned by this account")
	case errors.Is(err, sharing.ErrAlreadyShared):
		writeError(w, http.StatusConflict, "REVISION_CONFLICT", "folder is already shared with this account")

	default:
		log.Printf("internal error: %v", err)
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "an internal error occurred")
	}
}
