package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestRoutes(t *testing.T) {
	tests := []struct {
		method, path string
		failure      bool
		status       int
	}{
		{"GET", "/healthz", true, 200}, {"GET", "/readyz", false, 200},
		{"GET", "/readyz", true, 503}, {"GET", "/v1", false, 200},
		{"GET", "/v1/users", false, 404}, {"POST", "/readyz", false, 405},
		{"HEAD", "/readyz", false, 200},
	}
	for _, tt := range tests {
		t.Run(tt.method+tt.path+http.StatusText(tt.status), func(t *testing.T) {
			var logs bytes.Buffer
			h := New(slog.New(slog.NewJSONHandler(&logs, nil)), func(ctx context.Context) error {
				if _, ok := ctx.Deadline(); !ok {
					t.Error("readiness has no deadline")
				}
				if tt.failure {
					return errors.New("SECRET_DATABASE_URL")
				}
				return nil
			}, time.Second)
			request := httptest.NewRequest(tt.method, tt.path+"?token=SECRET_QUERY", nil)
			request.Header.Set("X-Request-ID", "attacker-controlled")
			w := httptest.NewRecorder()
			h.ServeHTTP(w, request)
			if w.Code != tt.status {
				t.Fatalf("status %d body %s", w.Code, w.Body)
			}
			id := w.Header().Get("X-Request-ID")
			if len(id) != 32 || id == "attacker-controlled" {
				t.Fatalf("bad request id %q", id)
			}
			if w.Header().Get("Cache-Control") != "no-store" || w.Header().Get("X-Content-Type-Options") != "nosniff" {
				t.Fatal("missing safety headers")
			}
			if tt.status == 405 && w.Header().Get("Allow") != "GET, HEAD" {
				t.Fatal("missing Allow header")
			}
			if tt.method == "HEAD" {
				if w.Body.Len() != 0 {
					t.Fatal("HEAD returned a body")
				}
			} else {
				var payload map[string]any
				if err := json.Unmarshal(w.Body.Bytes(), &payload); err != nil {
					t.Fatal(err)
				}
				if tt.status >= 400 && payload["error"].(map[string]any)["request_id"] != id {
					t.Fatal("request id mismatch")
				}
			}
			if strings.Contains(w.Body.String()+logs.String(), "SECRET") {
				t.Fatal("secret leaked into response or log")
			}
		})
	}
}

func TestReadinessPanicRecovery(t *testing.T) {
	var logs bytes.Buffer
	h := New(slog.New(slog.NewJSONHandler(&logs, nil)), func(context.Context) error { panic("SECRET") }, time.Second)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/readyz", nil))
	if w.Code != 500 || strings.Contains(logs.String()+w.Body.String(), "SECRET") {
		t.Fatalf("unsafe panic recovery: %s", w.Body)
	}
}

func TestReadinessCancellation(t *testing.T) {
	h := New(slog.Default(), func(ctx context.Context) error { <-ctx.Done(); return ctx.Err() }, time.Millisecond)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/readyz", nil))
	if w.Code != 503 {
		t.Fatalf("expected timeout to produce 503, got %d", w.Code)
	}
}
