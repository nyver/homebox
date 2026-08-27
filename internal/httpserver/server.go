package httpserver

import (
	"encoding/json"
	"net/http"
	"time"
)

// New wires operational endpoints (health/metrics) alongside the
// authenticated business API. The whole handler is only ever served over
// the Secure Transport TLS listener built by internal/securetransport
// (see cmd/homebox) — there is no plaintext HTTP mode. If api is nil, every
// business route rejects with 426 rather than silently doing nothing; this
// lets internal packages exercise the operational endpoints in isolation
// without an auth/database dependency.
func New(api http.Handler) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health/live", health)
	mux.HandleFunc("GET /health/ready", health)
	mux.HandleFunc("GET /metrics", metrics)
	if api != nil {
		mux.Handle("/api/", api)
	} else {
		mux.HandleFunc("/api/", secureTransportRequired)
	}
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
