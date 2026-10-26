package httpapi

import (
	"context"
	"crypto/sha256"
	"strings"
	"testing"
	"time"

	"catatuang/backend/internal/service"
)

type sessionsPage struct {
	Items   []service.AccountSession `json:"items"`
	Limit   int                      `json:"limit"`
	Offset  int                      `json:"offset"`
	HasMore bool                     `json:"has_more"`
}

func TestSessionListAndScopedRevocation(t *testing.T) {
	c := integrationClient(t)
	owner := c.register("sessions@example.com")
	other := decodeResponse[service.Session](t, c.request("POST", "/v1/auth/login", "", service.Credentials{Email: owner.User.Email, Password: originalPassword}, nil, 200))
	unrelated := c.register("sessions-unrelated@example.com")
	expiredHash := sha256.Sum256([]byte("expired-session-for-testing"))
	if _, err := c.pool.Exec(context.Background(), `INSERT INTO sessions(token_hash,user_id,created_at,expires_at) VALUES($1,$2,now()-interval '2 hours',now()-interval '1 hour')`, expiredHash[:], owner.User.ID); err != nil {
		t.Fatal(err)
	}
	c.request("GET", "/v1/auth/sessions", "", nil, nil, 401)
	w := c.request("GET", "/v1/auth/sessions", owner.AccessToken, nil, nil, 200)
	page := decodeResponse[sessionsPage](t, w)
	if len(page.Items) != 2 || !page.Items[0].Current || page.Items[1].Current || !service.ValidID(page.Items[0].ID) || page.Items[0].ID == page.Items[1].ID {
		t.Fatal("bad active-session list")
	}
	for _, secret := range []string{owner.AccessToken, other.AccessToken, "token_hash", "access_token"} {
		if strings.Contains(w.Body.String(), secret) {
			t.Fatal("session list exposed credentials")
		}
	}
	first := decodeResponse[sessionsPage](t, c.request("GET", "/v1/auth/sessions?limit=1", owner.AccessToken, nil, nil, 200))
	second := decodeResponse[sessionsPage](t, c.request("GET", "/v1/auth/sessions?limit=1&offset=1", owner.AccessToken, nil, nil, 200))
	if !first.HasMore || first.Items[0].ID != page.Items[0].ID || second.HasMore || second.Items[0].ID != page.Items[1].ID {
		t.Fatal("invalid session pagination")
	}
	if head := c.request("HEAD", "/v1/auth/sessions", owner.AccessToken, nil, nil, 200); head.Body.Len() != 0 {
		t.Fatal("HEAD body")
	}
	target := "/v1/auth/sessions/" + page.Items[1].ID
	c.request("DELETE", target, unrelated.AccessToken, nil, nil, 404)
	c.request("GET", "/v1/me", other.AccessToken, nil, nil, 200)
	c.request("DELETE", "/v1/auth/sessions/"+page.Items[0].ID, owner.AccessToken, nil, nil, 422)
	c.request("POST", "/v1/transactions", owner.AccessToken, syncInput(), nil, 201)
	c.request("DELETE", target, owner.AccessToken, nil, nil, 204)
	c.request("DELETE", target, owner.AccessToken, nil, nil, 404)
	c.request("GET", "/v1/me", other.AccessToken, nil, nil, 401)
	c.request("GET", "/v1/me", owner.AccessToken, nil, nil, 200)
	c.request("GET", "/v1/me", unrelated.AccessToken, nil, nil, 200)
	remaining := decodeResponse[sessionsPage](t, c.request("GET", "/v1/auth/sessions", owner.AccessToken, nil, nil, 200))
	if len(remaining.Items) != 1 || !remaining.Items[0].Current {
		t.Fatal("wrong sessions removed")
	}
	var count int
	if err := c.pool.QueryRow(context.Background(), `SELECT count(*) FROM transactions WHERE user_id=$1`, owner.User.ID).Scan(&count); err != nil || count != 1 {
		t.Fatal("finance changed", err)
	}
	for _, query := range []string{"limit=0", "limit=101", "offset=-1", "offset=10001", "offset=0&offset=1", "from=2026-01-01", "unknown=1"} {
		c.request("GET", "/v1/auth/sessions?"+query, owner.AccessToken, nil, nil, 422)
	}
	c.request("POST", "/v1/auth/sessions", owner.AccessToken, nil, nil, 405)
	c.request("GET", target, owner.AccessToken, nil, nil, 405)
	c.request("DELETE", target+"?all=true", owner.AccessToken, nil, nil, 422)
}

func TestRevokedSessionCannotActAfterWaitingForAccountLock(t *testing.T) {
	c := integrationClient(t)
	owner := c.register("session-race@example.com")
	other := decodeResponse[service.Session](t, c.request("POST", "/v1/auth/login", "", service.Credentials{Email: owner.User.Email, Password: originalPassword}, nil, 200))
	page := decodeResponse[sessionsPage](t, c.request("GET", "/v1/auth/sessions", owner.AccessToken, nil, nil, 200))
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	tx, err := c.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `SELECT id FROM users WHERE id=$1 FOR UPDATE`, owner.User.ID); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		done <- service.New(c.pool).RevokeSession(ctx, owner.User.ID, other.AccessToken, page.Items[0].ID)
	}()
	blocked := false
	for ctx.Err() == nil {
		if err = c.pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE 'SELECT id::text FROM users WHERE id=%')`).Scan(&blocked); err != nil {
			t.Fatal(err)
		}
		if blocked {
			break
		}
		select {
		case err := <-done:
			t.Fatal("mutation did not wait for lock", err)
		default:
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !blocked {
		t.Fatal("mutation never reached row lock")
	}
	if _, err = tx.Exec(ctx, `DELETE FROM sessions WHERE token_hash=$1`, hashTokenForTest(other.AccessToken)); err != nil {
		t.Fatal(err)
	}
	if err = tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err = <-done; err != service.ErrUnauthorized {
		t.Fatal("revoked caller acted after waiting", err)
	}
	c.request("GET", "/v1/me", owner.AccessToken, nil, nil, 200)
}
