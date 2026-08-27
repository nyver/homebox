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

	"github.com/homebox/homebox/internal/auth"
	"github.com/homebox/homebox/internal/provisioning"
)

// maxRequestBodyBytes is generous for JSON control-plane payloads. File
// bytes never transit this API (see the roadmap's upload service wiring).
const maxRequestBodyBytes = 1 << 20

type API struct {
	auth         *auth.Service
	provisioning *provisioning.Service
}

func New(authService *auth.Service, provisioningService *provisioning.Service) http.Handler {
	api := &API{auth: authService, provisioning: provisioningService}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/auth/login", api.login)
	mux.HandleFunc("POST /api/v1/auth/refresh", api.refresh)
	mux.HandleFunc("POST /api/v1/auth/logout", api.logout)
	mux.Handle("GET /api/v1/users/me", api.authenticated(api.getMe))
	mux.Handle("GET /api/v1/devices", api.authenticated(api.listDevices))
	mux.Handle("DELETE /api/v1/devices/{id}", api.authenticated(api.revokeDevice))
	mux.Handle("POST /api/v1/devices/{id}/key-envelope", api.authenticated(api.uploadKeyEnvelope))
	mux.Handle("GET /api/v1/devices/{id}/key-envelope", api.authenticated(api.downloadKeyEnvelope))
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
			writeAuthError(w, err)
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
		writeAuthError(w, err)
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
		writeAuthError(w, err)
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
		writeAuthError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"id": user.ID, "username": user.Username, "role": user.Role})
}

// --- devices ---

type deviceResponse struct {
	ID         string  `json:"id"`
	Name       string  `json:"name"`
	Platform   string  `json:"platform"`
	PublicKey  string  `json:"publicKey"`
	KeyVersion int     `json:"keyVersion"`
	CreatedAt  string  `json:"createdAt"`
	LastSeenAt string  `json:"lastSeenAt"`
	RevokedAt  *string `json:"revokedAt,omitempty"`
}

func toDeviceResponse(d auth.Device) deviceResponse {
	resp := deviceResponse{
		ID: d.ID, Name: d.Name, Platform: d.Platform, KeyVersion: d.KeyVersion,
		PublicKey:  base64.StdEncoding.EncodeToString(d.PublicKey),
		CreatedAt:  d.CreatedAt.Format(time.RFC3339Nano),
		LastSeenAt: d.LastSeenAt.Format(time.RFC3339Nano),
	}
	if d.RevokedAt != nil {
		revoked := d.RevokedAt.Format(time.RFC3339Nano)
		resp.RevokedAt = &revoked
	}
	return resp
}

func (a *API) listDevices(w http.ResponseWriter, r *http.Request) {
	devices, err := a.auth.ListDevices(r.Context(), requestUserID(r))
	if err != nil {
		log.Printf("list devices: %v", err)
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to list devices")
		return
	}
	out := make([]deviceResponse, 0, len(devices))
	for _, d := range devices {
		out = append(out, toDeviceResponse(d))
	}
	writeJSON(w, http.StatusOK, out)
}

func (a *API) revokeDevice(w http.ResponseWriter, r *http.Request) {
	targetDeviceID, ok := pathDeviceID(w, r)
	if !ok {
		return
	}
	if err := a.auth.RevokeDevice(r.Context(), requestUserID(r), targetDeviceID); err != nil {
		writeAuthError(w, err)
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
		writeAuthError(w, err)
		return
	}
	if target.RevokedAt != nil {
		writeAuthError(w, auth.ErrDeviceRevoked)
		return
	}
	envelope, err := a.provisioning.Upload(r.Context(), req.VaultID, userID, targetDeviceID, req.KeyVersion, ciphertext)
	if err != nil {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", err.Error())
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
		if errors.Is(err, provisioning.ErrNotFound) {
			writeError(w, http.StatusNotFound, "NOT_FOUND", "no key envelope is available yet")
			return
		}
		log.Printf("load key envelope: %v", err)
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to load key envelope")
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

// writeAuthError maps the auth package's sentinel errors to the spec §18
// error codes. The default branch is reached only by validation errors the
// service itself constructs (never a wrapped internal/database error), so
// surfacing err.Error() there does not leak sensitive detail.
func writeAuthError(w http.ResponseWriter, err error) {
	switch {
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
	default:
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", err.Error())
	}
}
