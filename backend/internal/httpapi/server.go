package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"runtime/debug"
	"strings"
	"time"

	"catatuang/backend/internal/service"
)

type Readiness func(context.Context) error

type API struct {
	logger         *slog.Logger
	ready          Readiness
	dbTimeout      time.Duration
	service        *service.Service
	trustedProxies []netip.Prefix
}

func NewTrusted(logger *slog.Logger, ready Readiness, timeout time.Duration, s *service.Service, proxies []netip.Prefix) http.Handler {
	a := New(logger, ready, timeout, s).(*API)
	a.trustedProxies = append([]netip.Prefix(nil), proxies...)
	return a
}
func (a *API) clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	peer, err := netip.ParseAddr(host)
	if err != nil {
		return host
	}
	peer = peer.Unmap()
	for _, prefix := range a.trustedProxies {
		if prefix.Contains(peer) && len(r.Header.Values("X-Forwarded-For")) == 1 {
			value, err := netip.ParseAddr(strings.TrimSpace(r.Header.Get("X-Forwarded-For")))
			if err == nil {
				return value.Unmap().String()
			}
		}
	}
	return peer.String()
}

func New(logger *slog.Logger, ready Readiness, dbTimeout time.Duration, services ...*service.Service) http.Handler {
	a := &API{logger: logger, ready: ready, dbTimeout: dbTimeout}
	if len(services) > 0 {
		a.service = services[0]
	}
	return a
}

type errorBody struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	RequestID string `json:"request_id"`
}
type responseWriter struct {
	http.ResponseWriter
	status int
}

func (w *responseWriter) WriteHeader(status int) {
	if w.status != 0 {
		return
	}
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}
func (w *responseWriter) Write(body []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(body)
}
func (w *responseWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (a *API) ServeHTTP(original http.ResponseWriter, r *http.Request) {
	started := time.Now()
	w := &responseWriter{ResponseWriter: original}
	var bytes [16]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		a.logger.Error("request ID generation failed")
		http.Error(w, "Service unavailable", http.StatusServiceUnavailable)
		return
	}
	requestID := hex.EncodeToString(bytes[:])
	w.Header().Set("X-Request-ID", requestID)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
	defer func() {
		if value := recover(); value != nil {
			// Panic values may contain user data; log only the stack and request ID.
			a.logger.Error("request panic", "request_id", requestID, "stack", string(debug.Stack()))
			if w.status == 0 {
				a.fail(w, r, http.StatusInternalServerError, "internal_error", "Terjadi kesalahan server.", requestID)
			}
		}
		a.logger.Info("http request", "request_id", requestID, "method", r.Method, "status", w.status, "duration_ms", time.Since(started).Milliseconds())
	}()
	if a.service != nil && a.serveData(w, r, requestID) {
		return
	}
	known := r.URL.Path == "/healthz" || r.URL.Path == "/readyz" || r.URL.Path == "/v1"
	if !known {
		a.fail(w, r, http.StatusNotFound, "not_found", "Endpoint tidak ditemukan.", requestID)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		a.fail(w, r, http.StatusMethodNotAllowed, "method_not_allowed", "Metode tidak diizinkan.", requestID)
		return
	}
	switch r.URL.Path {
	case "/healthz":
		a.json(w, r, http.StatusOK, map[string]string{"status": "ok"})
	case "/readyz":
		ctx, cancel := context.WithTimeout(r.Context(), a.dbTimeout)
		defer cancel()
		if err := a.ready(ctx); err != nil {
			a.fail(w, r, http.StatusServiceUnavailable, "not_ready", "Layanan belum siap.", requestID)
			return
		}
		a.json(w, r, http.StatusOK, map[string]string{"status": "ready"})
	case "/v1":
		a.json(w, r, http.StatusOK, map[string]string{"service": "catat-uang", "api_version": "v1", "stage": "authenticated-api"})
	}
}

func (a *API) fail(w http.ResponseWriter, r *http.Request, status int, code, message, id string) {
	a.json(w, r, status, struct {
		Error errorBody `json:"error"`
	}{Error: errorBody{code, message, id}})
}

func (a *API) json(w http.ResponseWriter, r *http.Request, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if r.Method != http.MethodHead {
		if err := json.NewEncoder(w).Encode(body); err != nil {
			a.logger.Warn("response write failed", "request_id", w.Header().Get("X-Request-ID"))
		}
	}
}
