package httpserver

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestBusinessAPIsRejectPlaintext(t *testing.T) {
	r := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", nil)
	w := httptest.NewRecorder()
	New(nil).ServeHTTP(w, r)
	if w.Code != http.StatusUpgradeRequired {
		t.Fatalf("status=%d, want %d", w.Code, http.StatusUpgradeRequired)
	}
	if got := w.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("cache control=%q", got)
	}
}
