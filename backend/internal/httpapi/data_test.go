package httpapi

import (
	"io"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestStrictJSON(t *testing.T) {
	a := &API{logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	for _, tt := range []struct {
		body, content string
		status        int
	}{
		{`{"name":"valid"}`, "application/json", 200},
		{`{"name":"a","name":"b"}`, "application/json", 400},
		{`{"name":"a","Name":"b"}`, "application/json", 400},
		{`{"unknown":"a"}`, "application/json", 400},
		{`{"name":"a"} {}`, "application/json", 400},
		{`null`, "application/json", 400},
		{`[]`, "application/json", 400},
		{`{"name":"a"}`, "text/plain", 415},
		{`{"name":"` + strings.Repeat("x", 17000) + `"}`, "application/json", 413},
	} {
		t.Run(tt.content+tt.body[:min(len(tt.body), 30)], func(t *testing.T) {
			r := httptest.NewRequest("POST", "/", strings.NewReader(tt.body))
			r.Header.Set("Content-Type", tt.content)
			w := httptest.NewRecorder()
			var value struct {
				Name string `json:"name"`
			}
			ok := a.decode(w, r, "id", &value)
			if (tt.status == 200) != ok || w.Code != tt.status {
				t.Fatalf("ok=%v status=%d body=%s", ok, w.Code, w.Body)
			}
		})
	}
}
func TestPaginationAndPreconditions(t *testing.T) {
	for _, query := range []string{"limit=0", "offset=-1", "limit=101", "limit=1&limit=2", "unknown=yes", "from=2026-02-29", "from=2026-10-02&to=2026-10-01", "%zz"} {
		if _, err := listOptions(httptest.NewRequest("GET", "/?"+query, nil), true); err == nil {
			t.Fatal("accepted query", query)
		}
	}
	a := &API{}
	for _, raw := range []string{"", "*", "1", `W/"1"`, `"01"`, `"-1"`, `"1","2"`} {
		w := httptest.NewRecorder()
		r := httptest.NewRequest("PUT", "/", nil)
		r.Header.Set("If-Match", raw)
		if _, ok := a.version(w, r, "id"); ok {
			t.Fatal("accepted precondition", raw)
		}
	}
	w := httptest.NewRecorder()
	r := httptest.NewRequest("PUT", "/", nil)
	r.Header.Set("If-Match", `"12"`)
	if n, ok := a.version(w, r, "id"); !ok || n != 12 {
		t.Fatal("valid precondition rejected")
	}
}
