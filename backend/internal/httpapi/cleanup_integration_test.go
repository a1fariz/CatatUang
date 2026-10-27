package httpapi

import (
	"catatuang/backend/internal/service"
	"context"
	"testing"
)

func cleanupFixture(t *testing.T) (*testClient, *service.Service, service.Session) {
	t.Helper()
	c, s := recoveryClient(t)
	expired := c.register("cleanup-expired@example.invalid")
	c.request("POST", "/v1/auth/password-reset/request", "", map[string]string{"email": expired.User.Email}, nil, 202)
	active := c.register("cleanup-active@example.invalid")
	c.request("POST", "/v1/auth/password-reset/request", "", map[string]string{"email": active.User.Email}, nil, 202)
	c.request("POST", "/v1/transactions", active.AccessToken, syncInput(), nil, 201)
	ctx := context.Background()
	for _, query := range []string{
		`UPDATE sessions SET created_at=now()-interval '2 days',expires_at=now()-interval '1 day' WHERE user_id=$1`,
		`UPDATE account_tokens SET expires_at=now()-interval '1 day' WHERE user_id=$1`,
		`UPDATE mail_outbox SET expires_at=now()-interval '1 day' WHERE user_id=$1`,
	} {
		if _, err := c.pool.Exec(ctx, query, expired.User.ID); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := c.pool.Exec(ctx, `INSERT INTO auth_rate_limits(key_hash,attempts,expires_at) VALUES(decode(repeat('ab',32),'hex'),1,now()-interval '1 day')`); err != nil {
		t.Fatal(err)
	}
	return c, s, active
}

func TestCleanupPreviewAndAtomicCounts(t *testing.T) {
	c, s, active := cleanupFixture(t)
	ctx := context.Background()
	finance := c.request("GET", "/v1/transactions", active.AccessToken, nil, nil, 200).Body.String()
	preview, err := s.CleanupReport(ctx, true)
	if err != nil {
		t.Fatal(err)
	}
	if !preview.DryRun || preview.Cutoff.IsZero() || preview.Sessions != 1 || preview.AuthRateLimits != 1 || preview.AccountTokens != 1 || preview.MailOutbox != 1 {
		t.Fatalf("incorrect preview: %+v", preview)
	}
	again, err := s.CleanupReport(ctx, true)
	if err != nil || again.Sessions != 1 || again.AccountTokens != 1 || again.MailOutbox != 1 {
		t.Fatal("preview deleted records")
	}
	actual, err := s.CleanupReport(ctx, false)
	if err != nil {
		t.Fatal(err)
	}
	if actual.DryRun || actual.Sessions != 1 || actual.AuthRateLimits != 1 || actual.AccountTokens != 1 || actual.MailOutbox != 1 {
		t.Fatalf("incorrect deletion counts: %+v", actual)
	}
	empty, err := s.CleanupReport(ctx, true)
	if err != nil || empty.Sessions+empty.AuthRateLimits+empty.AccountTokens+empty.MailOutbox != 0 {
		t.Fatal("cleanup not idempotent")
	}
	c.request("GET", "/v1/me", active.AccessToken, nil, nil, 200)
	if c.request("GET", "/v1/transactions", active.AccessToken, nil, nil, 200).Body.String() != finance {
		t.Fatal("cleanup changed finance")
	}
	for _, table := range []string{"account_tokens", "mail_outbox"} {
		var count int
		if err = c.pool.QueryRow(ctx, "SELECT count(*) FROM "+table+" WHERE user_id=$1", active.User.ID).Scan(&count); err != nil || count != 1 {
			t.Fatal("cleanup removed active recovery records")
		}
	}
}

func TestCleanupFailureRollsBackAllTables(t *testing.T) {
	c, s, _ := cleanupFixture(t)
	ctx := context.Background()
	if _, err := c.pool.Exec(ctx, `CREATE FUNCTION reject_cleanup_mail() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture failure'; END; $$; CREATE TRIGGER reject_cleanup_mail BEFORE DELETE ON mail_outbox FOR EACH ROW EXECUTE FUNCTION reject_cleanup_mail()`); err != nil {
		t.Fatal(err)
	}
	report, err := s.CleanupReport(ctx, false)
	if err == nil || report != (service.CleanupSummary{}) {
		t.Fatal("failed cleanup reported partial success")
	}
	preview, err := s.CleanupReport(ctx, true)
	if err != nil || preview.Sessions != 1 || preview.AuthRateLimits != 1 || preview.AccountTokens != 1 || preview.MailOutbox != 1 {
		t.Fatal("failed cleanup did not roll back all tables")
	}
}
