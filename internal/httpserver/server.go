package httpserver

import (
	"encoding/json"
	"net/http"
	"time"
)

// New exposes only unauthenticated operational endpoints until a vetted,
// interoperable secure-transport implementation is available. Business APIs
// deliberately reject plaintext HTTP rather than silently weakening security.
func New() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health/live", health)
	mux.HandleFunc("GET /health/ready", health)
	mux.HandleFunc("GET /metrics", metrics)
	mux.HandleFunc("/api/", secureTransportRequired)
	return securityHeaders(mux)
}

func health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "time": time.Now().UTC().Format(time.RFC3339Nano)})
}

func metrics(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	_, _ = w.Write([]byte("homebox_server_ready 1\n"))
}

func secureTransportRequired(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Upgrade", "homebox-secure/1")
	writeJSON(w, http.StatusUpgradeRequired, map[string]string{"code": "SECURE_TRANSPORT_REQUIRED", "message": "plaintext business APIs are disabled"})
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
