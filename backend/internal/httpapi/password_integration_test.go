package httpapi

import (
	"context"
	"crypto/sha256"
	"fmt"
	"testing"
	"time"

	"catatuang/backend/internal/service"
)

const originalPassword = "rahasia-untuk-pengujian-2026"
const replacementPassword = "kata-sandi-baru-untuk-pengujian-2026"

func TestPasswordChangeRevokesOtherSessionsAndPreservesFinance(t *testing.T) {
	c := integrationClient(t)
	owner := c.register("password@example.com")
	other := decodeResponse[service.Session](t, c.request("POST", "/v1/auth/login", "", service.Credentials{Email: owner.User.Email, Password: originalPassword}, nil, 200))
	anotherUser := c.register("unrelated@example.com")
	in := service.PasswordChange{CurrentPassword: originalPassword, NewPassword: replacementPassword}
	c.request("POST", "/v1/transactions", owner.AccessToken, syncInput(), nil, 201)
	c.request("POST", "/v1/auth/change-password", "", in, nil, 401)
	c.request("GET", "/v1/auth/change-password", owner.AccessToken, nil, nil, 405)
	bad := in
	bad.CurrentPassword = "kata-sandi-lama-yang-salah"
	c.request("POST", "/v1/auth/change-password", owner.AccessToken, bad, nil, 422)
	c.request("GET", "/v1/me", other.AccessToken, nil, nil, 200)
	c.request("POST", "/v1/auth/change-password", owner.AccessToken, in, nil, 204)
	c.request("GET", "/v1/me", owner.AccessToken, nil, nil, 200)
	c.request("GET", "/v1/me", other.AccessToken, nil, nil, 401)
	c.request("GET", "/v1/me", anotherUser.AccessToken, nil, nil, 200)
	c.request("POST", "/v1/auth/login", "", service.Credentials{Email: owner.User.Email, Password: originalPassword}, nil, 401)
	c.request("POST", "/v1/auth/login", "", service.Credentials{Email: owner.User.Email, Password: replacementPassword}, nil, 200)
	c.request("POST", "/v1/auth/change-password", other.AccessToken, in, nil, 401)
	var hash string
	var count int
	var expires time.Time
	ctx := context.Background()
	if err := c.pool.QueryRow(ctx, `SELECT password_hash FROM users WHERE id=$1`, owner.User.ID).Scan(&hash); err != nil {
		t.Fatal(err)
	}
	if hash == replacementPassword || !service.CheckPassword(hash, replacementPassword) {
		t.Fatal("replacement is not a valid password hash")
	}
	if err := c.pool.QueryRow(ctx, `SELECT count(*) FROM transactions WHERE user_id=$1`, owner.User.ID).Scan(&count); err != nil || count != 1 {
		t.Fatal("finance changed", err)
	}
	if err := c.pool.QueryRow(ctx, `SELECT expires_at FROM sessions WHERE token_hash=$1`, hashTokenForTest(owner.AccessToken)).Scan(&expires); err != nil || !expires.Equal(owner.ExpiresAt) {
		t.Fatal("retained session expiry changed", err)
	}
}

func hashTokenForTest(token string) []byte { sum := sha256.Sum256([]byte(token)); return sum[:] }

func TestPasswordChangeRollsBackIfSessionRevocationFails(t *testing.T) {
	c := integrationClient(t)
	owner := c.register("password-rollback@example.com")
	other := decodeResponse[service.Session](t, c.request("POST", "/v1/auth/login", "", service.Credentials{Email: owner.User.Email, Password: originalPassword}, nil, 200))
	ctx := context.Background()
	if _, err := c.pool.Exec(ctx, `CREATE FUNCTION fail_session_delete() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'simulated revocation failure'; END; $$; CREATE TRIGGER sessions_no_delete BEFORE DELETE ON sessions FOR EACH ROW EXECUTE FUNCTION fail_session_delete()`); err != nil {
		t.Fatal(err)
	}
	c.request("POST", "/v1/auth/change-password", owner.AccessToken, service.PasswordChange{CurrentPassword: originalPassword, NewPassword: replacementPassword}, nil, 500)
	var hash string
	if err := c.pool.QueryRow(ctx, `SELECT password_hash FROM users WHERE id=$1`, owner.User.ID).Scan(&hash); err != nil || !service.CheckPassword(hash, originalPassword) {
		t.Fatal("password survived failed revocation", err)
	}
	c.request("GET", "/v1/me", owner.AccessToken, nil, nil, 200)
	c.request("GET", "/v1/me", other.AccessToken, nil, nil, 200)
}

func TestPasswordChangeRevalidatesSessionInTransaction(t *testing.T) {
	c := integrationClient(t)
	owner := c.register("password-session@example.com")
	err := service.New(c.pool).ChangePassword(context.Background(), owner.User.ID, "not-the-authorized-token", service.PasswordChange{CurrentPassword: originalPassword, NewPassword: replacementPassword})
	if err != service.ErrUnauthorized {
		t.Fatal("password change accepted invalid session", err)
	}
	var hash string
	if err = c.pool.QueryRow(context.Background(), `SELECT password_hash FROM users WHERE id=$1`, owner.User.ID).Scan(&hash); err != nil || !service.CheckPassword(hash, originalPassword) {
		t.Fatal("unauthorized password change committed", err)
	}
}

func TestPasswordChangeValidationAndRateLimit(t *testing.T) {
	c := integrationClient(t)
	owner := c.register("password-limit@example.com")
	for _, input := range []service.PasswordChange{
		{CurrentPassword: originalPassword, NewPassword: originalPassword}, {CurrentPassword: originalPassword, NewPassword: "short"}, {CurrentPassword: "", NewPassword: replacementPassword},
	} {
		c.request("POST", "/v1/auth/change-password", owner.AccessToken, input, nil, 422)
	}
	c.request("POST", "/v1/auth/change-password?new_password=ignored", owner.AccessToken, service.PasswordChange{CurrentPassword: originalPassword, NewPassword: replacementPassword}, nil, 422)
	c.request("POST", "/v1/auth/change-password", owner.AccessToken, map[string]string{"current_password": originalPassword, "new_password": replacementPassword, "user_id": service.NewID()}, nil, 400)
	bucket := sha256.Sum256([]byte("account:password-change:" + owner.User.ID))
	if _, err := c.pool.Exec(context.Background(), `INSERT INTO auth_rate_limits(key_hash,attempts,expires_at) VALUES($1,20,now()+interval '15 minutes') ON CONFLICT(key_hash) DO UPDATE SET attempts=20`, bucket[:]); err != nil {
		t.Fatal(err)
	}
	limited := c.request("POST", "/v1/auth/change-password", owner.AccessToken, service.PasswordChange{CurrentPassword: originalPassword, NewPassword: replacementPassword}, nil, 429)
	if limited.Header().Get("Retry-After") != "900" {
		t.Fatal("missing cooldown")
	}
	var hash string
	if err := c.pool.QueryRow(context.Background(), `SELECT password_hash FROM users WHERE id=$1`, owner.User.ID).Scan(&hash); err != nil || !service.CheckPassword(hash, originalPassword) {
		t.Fatal("rate limited request changed password", err)
	}
}

func TestLoginCannotIssueSessionFromStalePasswordVerification(t *testing.T) {
	c := integrationClient(t)
	owner := c.register("password-race@example.com")
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	replacement := service.HashPassword(replacementPassword)
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
		_, err := service.New(c.pool).Authenticate(ctx, service.Credentials{Email: owner.User.Email, Password: originalPassword}, false)
		done <- err
	}()
	blocked := false
	for ctx.Err() == nil {
		if err = c.pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE 'SELECT password_hash FROM users WHERE id=%')`).Scan(&blocked); err != nil {
			t.Fatal(err)
		}
		if blocked {
			break
		}
		select {
		case err := <-done:
			t.Fatal("login did not wait for the password row lock", err)
		default:
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !blocked {
		t.Fatal("login never reached serialization point")
	}
	if _, err = tx.Exec(ctx, `UPDATE users SET password_hash=$2 WHERE id=$1`, owner.User.ID, replacement); err != nil {
		t.Fatal(err)
	}
	if err = tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err = <-done; err != service.ErrUnauthorized {
		t.Fatal("stale login issued a session", err)
	}
	var count int
	if err = c.pool.QueryRow(ctx, `SELECT count(*) FROM sessions WHERE user_id=$1`, owner.User.ID).Scan(&count); err != nil || count != 1 {
		t.Fatal(fmt.Sprintf("unexpected sessions: %d", count), err)
	}
}
