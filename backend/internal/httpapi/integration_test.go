package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"catatuang/backend/internal/config"
	"catatuang/backend/internal/database"
	"catatuang/backend/internal/service"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type testClient struct {
	t       *testing.T
	handler http.Handler
	pool    *pgxpool.Pool
}

func integrationClient(t *testing.T) *testClient {
	t.Helper()
	raw := os.Getenv("TEST_DATABASE_URL")
	if raw == "" {
		t.Skip("set TEST_DATABASE_URL for API integration tests")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	admin, err := pgx.Connect(ctx, raw)
	if err != nil {
		t.Fatal("integration database unavailable")
	}
	name := fmt.Sprintf("catatuang_http_%d", time.Now().UnixNano())
	if _, err = admin.Exec(ctx, "CREATE DATABASE "+pgx.Identifier{name}.Sanitize()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if _, err := admin.Exec(ctx, "DROP DATABASE "+pgx.Identifier{name}.Sanitize()+" WITH (FORCE)"); err != nil {
			t.Error(err)
		}
		_ = admin.Close(ctx)
	})
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal("invalid test URL")
	}
	u.Path = "/" + name
	pool, err := database.Open(ctx, config.Config{DatabaseURL: u.String(), MaxConnections: 5, DBTimeout: 3 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if _, err = database.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	handler := New(slog.New(slog.NewJSONHandler(io.Discard, nil)), func(ctx context.Context) error { return database.CheckSchema(ctx, pool) }, 3*time.Second, service.New(pool))
	return &testClient{t, handler, pool}
}
func (c *testClient) request(method, path, token string, body any, headers map[string]string, status int) *httptest.ResponseRecorder {
	c.t.Helper()
	var data []byte
	if body != nil {
		var err error
		data, err = json.Marshal(body)
		if err != nil {
			c.t.Fatal(err)
		}
	}
	r := httptest.NewRequest(method, path, bytes.NewReader(data))
	r.RemoteAddr = "127.0.0.1:12345"
	r.Header.Set("Content-Type", "application/json")
	if strings.HasPrefix(path, "/v1/sync/transactions") {
		var dataset string
		if err := c.pool.QueryRow(context.Background(), `SELECT dataset_id::text FROM sync_dataset WHERE id=1`).Scan(&dataset); err != nil {
			c.t.Fatal(err)
		}
		r.Header.Set("X-Sync-Dataset", dataset)
	}
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	for key, value := range headers {
		r.Header.Set(key, value)
	}
	w := httptest.NewRecorder()
	c.handler.ServeHTTP(w, r)
	if w.Code != status {
		c.t.Fatalf("%s %s: want %d got %d body %s", method, path, status, w.Code, w.Body)
	}
	return w
}
func decodeResponse[T any](t *testing.T, w *httptest.ResponseRecorder) T {
	t.Helper()
	var result T
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	return result
}
func (c *testClient) register(email string) service.Session {
	return decodeResponse[service.Session](c.t, c.request("POST", "/v1/auth/register", "", service.Credentials{Email: email, Password: "rahasia-untuk-pengujian-2026"}, nil, 201))
}

func TestAuthenticatedTransactionAPI(t *testing.T) {
	c := integrationClient(t)
	owner, other := c.register("Owner@Example.com"), c.register("other@example.com")
	if owner.User.Email != "owner@example.com" || owner.TokenType != "Bearer" {
		t.Fatal("bad registration response")
	}
	c.request("POST", "/v1/auth/register", "", service.Credentials{Email: "owner@example.com", Password: "rahasia-untuk-pengujian-2026"}, nil, 409)
	c.request("POST", "/v1/auth/login", "", service.Credentials{Email: "owner@example.com", Password: "password-yang-salah"}, nil, 401)
	c.request("POST", "/v1/auth/login", "", service.Credentials{Email: "unknown@example.com", Password: "password-yang-salah"}, nil, 401)
	logged := decodeResponse[service.Session](t, c.request("POST", "/v1/auth/login", "", service.Credentials{Email: "owner@example.com", Password: "rahasia-untuk-pengujian-2026"}, nil, 200))
	c.request("GET", "/v1/me", owner.AccessToken, nil, nil, 200)
	c.request("GET", "/v1/transactions", "", nil, nil, 401)
	c.request("GET", "/v1/transactions", "made-up-token", nil, nil, 401)
	in := service.TransactionInput{Type: "expense", AmountMinor: 42000, CurrencyCode: "IDR", Category: "Makan", OccurredOn: "2026-10-25", Note: "Makan siang"}
	w := c.request("POST", "/v1/transactions", owner.AccessToken, in, nil, 201)
	created := decodeResponse[service.Transaction](t, w)
	if w.Header().Get("ETag") != `"1"` || created.ID == "" || created.Version != 1 {
		t.Fatal("missing concurrency metadata")
	}
	path := "/v1/transactions/" + created.ID
	for _, method := range []string{"GET", "PUT", "DELETE"} {
		var body any
		if method == "PUT" {
			body = in
		}
		c.request(method, path, other.AccessToken, body, map[string]string{"If-Match": `"1"`}, 404)
	}
	empty := decodeResponse[struct {
		Items []service.Transaction `json:"items"`
	}](t, c.request("GET", "/v1/transactions", other.AccessToken, nil, nil, 200))
	if len(empty.Items) != 0 {
		t.Fatal("cross-account list leaked")
	}
	c.request("PUT", path, owner.AccessToken, in, nil, 428)
	in.AmountMinor = 50000
	updated := decodeResponse[service.Transaction](t, c.request("PUT", path, owner.AccessToken, in, map[string]string{"If-Match": `"1"`}, 200))
	if updated.Version != 2 || updated.AmountMinor != 50000 {
		t.Fatal("update failed")
	}
	c.request("PUT", path, owner.AccessToken, in, map[string]string{"If-Match": `"1"`}, 409)
	list := decodeResponse[struct {
		Items   []service.Transaction `json:"items"`
		HasMore bool                  `json:"has_more"`
	}](t, c.request("GET", "/v1/transactions?from=2026-10-01&to=2026-11-01&type=expense&limit=1", owner.AccessToken, nil, nil, 200))
	if len(list.Items) != 1 || list.Items[0].ID != created.ID {
		t.Fatal("period filter failed")
	}
	empty = decodeResponse[struct {
		Items []service.Transaction `json:"items"`
	}](t, c.request("GET", "/v1/transactions?from=2026-11-01", owner.AccessToken, nil, nil, 200))
	if len(empty.Items) != 0 {
		t.Fatal("from-only filter failed")
	}
	bad := in
	bad.Category = "Gaji"
	c.request("POST", "/v1/transactions", owner.AccessToken, bad, nil, 422)
	bad = in
	bad.AmountMinor = service.MaxAmount + 1
	c.request("POST", "/v1/transactions", owner.AccessToken, bad, nil, 422)
	c.request("DELETE", path, owner.AccessToken, nil, map[string]string{"If-Match": `"2"`}, 204)
	c.request("GET", path, owner.AccessToken, nil, nil, 404)
	c.request("POST", "/v1/auth/logout", logged.AccessToken, nil, nil, 204)
	c.request("GET", "/v1/me", logged.AccessToken, nil, nil, 401)
	c.request("GET", "/v1/me", owner.AccessToken, nil, nil, 200)
	c.request("POST", "/v1/auth/logout-all", owner.AccessToken, nil, nil, 204)
	c.request("GET", "/v1/me", owner.AccessToken, nil, nil, 401)
	c.request("GET", "/v1/me", other.AccessToken, nil, nil, 200)
	var hash string
	var leaked bool
	if err := c.pool.QueryRow(context.Background(), "SELECT password_hash FROM users WHERE id=$1", owner.User.ID).Scan(&hash); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(hash, "$argon2id$") {
		t.Fatal("password not hashed")
	}
	if err := c.pool.QueryRow(context.Background(), "SELECT EXISTS(SELECT 1 FROM sessions WHERE token_hash=convert_to($1,'UTF8'))", other.AccessToken).Scan(&leaked); err != nil || leaked {
		t.Fatal("raw token stored", err)
	}
}

func TestBillPaymentAPI(t *testing.T) {
	c := integrationClient(t)
	owner, other := c.register("bill@example.com"), c.register("intruder@example.com")
	due, _ := time.Parse(time.RFC3339, "2030-01-31T09:00:00+07:00")
	reminder := 60
	in := service.BillInput{Name: "Internet", AmountMinor: 125000, CurrencyCode: "IDR", DueAt: due, Timezone: "Asia/Jakarta", Recurrence: "monthly", RecurrenceDay: 31, ReminderMinutes: &reminder}
	created := decodeResponse[service.Bill](t, c.request("POST", "/v1/bills", owner.AccessToken, in, nil, 201))
	path := "/v1/bills/" + created.ID
	c.request("GET", path, other.AccessToken, nil, nil, 404)
	c.request("PUT", path, other.AccessToken, in, map[string]string{"If-Match": `"1"`}, 404)
	c.request("DELETE", path, other.AccessToken, nil, map[string]string{"If-Match": `"1"`}, 404)
	c.request("GET", path+"/payments", other.AccessToken, nil, nil, 404)
	pay := map[string]any{"due_at": due}
	headers := map[string]string{"If-Match": `"1"`, "Idempotency-Key": service.NewID()}
	c.request("POST", path+"/pay", other.AccessToken, pay, headers, 404)
	c.request("POST", path+"/pay", owner.AccessToken, pay, map[string]string{"If-Match": `"1"`}, 422)
	first := decodeResponse[service.PaymentResult](t, c.request("POST", path+"/pay", owner.AccessToken, pay, headers, 200))
	if first.Bill.Version != 2 || first.Bill.DueAt.In(mustZone(t, "Asia/Jakarta")).Day() != 28 || first.Replayed {
		t.Fatal("payment advance failed")
	}
	replay := decodeResponse[service.PaymentResult](t, c.request("POST", path+"/pay", owner.AccessToken, pay, headers, 200))
	if !replay.Replayed || replay.Payment.ID != first.Payment.ID || replay.Bill.Version != 2 {
		t.Fatal("retry duplicated payment")
	}
	c.request("POST", path+"/pay", owner.AccessToken, pay, map[string]string{"If-Match": `"1"`, "Idempotency-Key": service.NewID()}, 409)
	// Concurrent payments for the same occurrence: exactly one succeeds.
	var wg sync.WaitGroup
	statuses := make(chan int, 2)
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			data, _ := json.Marshal(map[string]any{"due_at": first.Bill.DueAt})
			r := httptest.NewRequest("POST", path+"/pay", bytes.NewReader(data))
			r.Header.Set("Content-Type", "application/json")
			r.Header.Set("Authorization", "Bearer "+owner.AccessToken)
			r.Header.Set("If-Match", `"2"`)
			r.Header.Set("Idempotency-Key", service.NewID())
			w := httptest.NewRecorder()
			c.handler.ServeHTTP(w, r)
			statuses <- w.Code
		}()
	}
	wg.Wait()
	close(statuses)
	counts := map[int]int{}
	for status := range statuses {
		counts[status]++
	}
	if counts[200] != 1 || counts[409] != 1 {
		t.Fatal("concurrent payment statuses", counts)
	}
	current := decodeResponse[service.Bill](t, c.request("GET", path, owner.AccessToken, nil, nil, 200))
	if current.Version != 3 || current.DueAt.In(mustZone(t, "Asia/Jakarta")).Day() != 31 {
		t.Fatal("anchor date lost")
	}
	history := decodeResponse[struct {
		Items []service.Payment `json:"items"`
	}](t, c.request("GET", path+"/payments", owner.AccessToken, nil, nil, 200))
	if len(history.Items) != 2 {
		t.Fatal("incorrect payment history")
	}
	in.DueAt = current.DueAt
	in.Name = "Internet baru"
	c.request("PUT", path, owner.AccessToken, in, map[string]string{"If-Match": `"3"`}, 200)
	c.request("DELETE", path, owner.AccessToken, nil, map[string]string{"If-Match": `"3"`}, 409)
	c.request("DELETE", path, owner.AccessToken, nil, map[string]string{"If-Match": `"4"`}, 204)
	c.request("GET", path, owner.AccessToken, nil, nil, 404)
}
func mustZone(t *testing.T, name string) *time.Location {
	t.Helper()
	z, err := time.LoadLocation(name)
	if err != nil {
		t.Fatal(err)
	}
	return z
}

func TestOneTimePaymentAndPagination(t *testing.T) {
	c := integrationClient(t)
	owner := c.register("once@example.com")
	due := time.Date(2030, 1, 10, 9, 0, 0, 0, time.UTC)
	input := service.BillInput{Name: "Pajak", AmountMinor: 100, CurrencyCode: "IDR", DueAt: due, Timezone: "UTC", Recurrence: "once", RecurrenceDay: 10}
	bill := decodeResponse[service.Bill](t, c.request("POST", "/v1/bills", owner.AccessToken, input, nil, 201))
	path := "/v1/bills/" + bill.ID
	headers := map[string]string{"If-Match": `"1"`, "Idempotency-Key": service.NewID()}
	result := decodeResponse[service.PaymentResult](t, c.request("POST", path+"/pay", owner.AccessToken, map[string]any{"due_at": due}, headers, 200))
	if result.Bill.Status != "paid" || result.Bill.PaidAt == nil || result.Bill.Version != 2 {
		t.Fatal("one-time payment failed")
	}
	c.request("PUT", path, owner.AccessToken, input, map[string]string{"If-Match": `"2"`}, 409)
	c.request("POST", path+"/pay", owner.AccessToken, map[string]any{"due_at": due}, headers, 200)
	c.request("POST", path+"/pay", owner.AccessToken, map[string]any{"due_at": due.Add(24 * time.Hour)}, headers, 409)
	for range 2 {
		c.request("POST", "/v1/bills", owner.AccessToken, input, nil, 201)
	}
	list := decodeResponse[struct {
		Items   []service.Bill `json:"items"`
		HasMore bool           `json:"has_more"`
	}](t, c.request("GET", "/v1/bills?limit=1", owner.AccessToken, nil, nil, 200))
	if len(list.Items) != 1 || !list.HasMore {
		t.Fatal("pagination lookahead failed")
	}
	last := decodeResponse[struct {
		Items   []service.Bill `json:"items"`
		HasMore bool           `json:"has_more"`
	}](t, c.request("GET", "/v1/bills?limit=1&offset=2", owner.AccessToken, nil, nil, 200))
	if len(last.Items) != 1 || last.HasMore {
		t.Fatal("pagination offset failed")
	}
	c.request("DELETE", path, owner.AccessToken, nil, map[string]string{"If-Match": `"2"`}, 204)
	var count int
	if err := c.pool.QueryRow(context.Background(), "SELECT count(*) FROM bill_payments WHERE bill_id=$1", bill.ID).Scan(&count); err != nil || count != 1 {
		t.Fatal("soft delete lost history", err)
	}
}

func TestSessionExpiryAndRateLimit(t *testing.T) {
	c := integrationClient(t)
	session := c.register("expiry@example.com")
	if _, err := c.pool.Exec(context.Background(), "UPDATE sessions SET created_at=now()-interval '2 days',expires_at=now()-interval '1 day' WHERE user_id=$1", session.User.ID); err != nil {
		t.Fatal(err)
	}
	c.request("GET", "/v1/me", session.AccessToken, nil, nil, 401)
	svc := service.New(c.pool)
	for i := 0; i < 20; i++ {
		if err := svc.LimitAuth(context.Background(), "rate-test", "rate@example.com"); err != nil {
			t.Fatal(err)
		}
	}
	if err := svc.LimitAuth(context.Background(), "rate-test", "rate@example.com"); err != service.ErrRateLimited {
		t.Fatal("limit not enforced", err)
	}
	// Limits survive service instance recreation; forwarded IP does not bypass them.
	c.request("POST", "/v1/auth/login", "", service.Credentials{Email: "rate@example.com", Password: "password-untuk-pengujian"}, map[string]string{"X-Forwarded-For": "different-address"}, 429)
	if err := svc.Cleanup(context.Background()); err != nil {
		t.Fatal(err)
	}
	var count int
	if err := c.pool.QueryRow(context.Background(), "SELECT count(*) FROM sessions").Scan(&count); err != nil || count != 0 {
		t.Fatal("expired session cleanup failed", err)
	}
}
