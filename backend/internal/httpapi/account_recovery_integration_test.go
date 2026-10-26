package httpapi

import (
	"bytes"
	"catatuang/backend/internal/service"
	"context"
	"io"
	"log/slog"
	"regexp"
	"sync"
	"testing"
	"time"
)

func recoveryClient(t *testing.T) (*testClient, *service.Service) {
	c := integrationClient(t)
	s := service.New(c.pool)
	if err := s.ConfigureMail(bytes.Repeat([]byte{7}, 32)); err != nil {
		t.Fatal(err)
	}
	c.handler = New(slog.New(slog.NewJSONHandler(io.Discard, nil)), func(context.Context) error { return nil }, 3*time.Second, s)
	return c, s
}
func mailToken(t *testing.T, s *service.Service) string {
	t.Helper()
	message, err := s.ClaimMail(context.Background())
	if err != nil || message == nil {
		t.Fatal("mail not queued")
	}
	token := regexp.MustCompile(`[A-Za-z0-9_-]{43}`).FindString(message.Body)
	if token == "" {
		t.Fatal("token missing from encrypted message")
	}
	if err = s.FinishMail(context.Background(), *message, true); err != nil {
		t.Fatal(err)
	}
	return token
}
func TestAccountEmailVerificationAndReset(t *testing.T) {
	c, s := recoveryClient(t)
	owner := c.register("recovery@example.com")
	c.request("POST", "/v1/auth/email-verification/request", "", nil, nil, 401)
	c.request("POST", "/v1/auth/email-verification/request", owner.AccessToken, nil, nil, 202)
	verification := mailToken(t, s)
	c.request("POST", "/v1/auth/password-reset/confirm", "", map[string]string{"token": verification, "new_password": "password-baru-pengujian-2026"}, nil, 422)
	c.request("POST", "/v1/auth/email-verification/confirm", "", map[string]string{"token": verification}, nil, 204)
	user := decodeResponse[service.User](t, c.request("GET", "/v1/me", owner.AccessToken, nil, nil, 200))
	if !user.EmailVerified {
		t.Fatal("email unverified after confirmation")
	}
	c.request("POST", "/v1/auth/email-verification/confirm", "", map[string]string{"token": verification}, nil, 422)
	known := c.request("POST", "/v1/auth/password-reset/request", "", map[string]string{"email": owner.User.Email}, nil, 202)
	unknown := c.request("POST", "/v1/auth/password-reset/request", "", map[string]string{"email": "unknown@example.com"}, nil, 202)
	if known.Body.String() != unknown.Body.String() {
		t.Fatal("address enumeration through response")
	}
	reset := mailToken(t, s)
	input := map[string]string{"token": reset, "new_password": "password-baru-pengujian-2026"}
	c.request("POST", "/v1/auth/password-reset/confirm", "", input, nil, 204)
	c.request("POST", "/v1/auth/password-reset/confirm", "", input, nil, 422)
	c.request("GET", "/v1/me", owner.AccessToken, nil, nil, 401)
	c.request("POST", "/v1/auth/login", "", service.Credentials{Email: owner.User.Email, Password: "rahasia-untuk-pengujian-2026"}, nil, 401)
	login := decodeResponse[service.Session](t, c.request("POST", "/v1/auth/login", "", service.Credentials{Email: owner.User.Email, Password: input["new_password"]}, nil, 200))
	if !login.User.EmailVerified {
		t.Fatal("verified status lost")
	}
}
func TestAccountTokensExpiryReplacementAndConcurrentConsume(t *testing.T) {
	c, s := recoveryClient(t)
	owner := c.register("expiry@example.com")
	ctx := context.Background()
	request := func() {
		c.request("POST", "/v1/auth/password-reset/request", "", map[string]string{"email": owner.User.Email}, nil, 202)
	}
	request()
	old := mailToken(t, s)
	request()
	fresh := mailToken(t, s)
	if err := s.ConsumeAccountToken(ctx, old, "reset", "password-baru-pengujian-2026"); err != service.ErrInvalid {
		t.Fatal("superseded token accepted")
	}
	if _, err := c.pool.Exec(ctx, `UPDATE account_tokens SET expires_at=now()-interval '1 second'`); err != nil {
		t.Fatal(err)
	}
	if err := s.ConsumeAccountToken(ctx, fresh, "reset", "password-baru-pengujian-2026"); err != service.ErrInvalid {
		t.Fatal("expired token accepted")
	}
	request()
	fresh = mailToken(t, s)
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results <- s.ConsumeAccountToken(ctx, fresh, "reset", "password-baru-pengujian-2026")
		}()
	}
	wg.Wait()
	close(results)
	success := 0
	for err := range results {
		if err == nil {
			success++
		} else if err != service.ErrInvalid {
			t.Fatal(err)
		}
	}
	if success != 1 {
		t.Fatal("token consumed more than once")
	}
}
func TestEncryptedMailLeaseRetryAndTamper(t *testing.T) {
	c, s := recoveryClient(t)
	owner := c.register("lease@example.com")
	ctx := context.Background()
	c.request("POST", "/v1/auth/password-reset/request", "", map[string]string{"email": owner.User.Email}, nil, 202)
	first, err := s.ClaimMail(ctx)
	if err != nil || first == nil {
		t.Fatal("claim failed")
	}
	var encrypted []byte
	if err = c.pool.QueryRow(ctx, `SELECT encrypted_body FROM mail_outbox WHERE id=$1`, first.ID).Scan(&encrypted); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(encrypted, []byte(first.Body)) {
		t.Fatal("plaintext outbox")
	}
	if next, err := s.ClaimMail(ctx); err != nil || next != nil {
		t.Fatal("leased job claimed twice")
	}
	if err = s.FinishMail(ctx, *first, false); err != nil {
		t.Fatal(err)
	}
	if next, _ := s.ClaimMail(ctx); next != nil {
		t.Fatal("retry backoff ignored")
	}
	if _, err = c.pool.Exec(ctx, `UPDATE mail_outbox SET available_at=now()-interval '1 second'`); err != nil {
		t.Fatal(err)
	}
	second, err := s.ClaimMail(ctx)
	if err != nil || second == nil || second.LeaseID == first.LeaseID {
		t.Fatal("retry failed")
	}
	if err = s.FinishMail(ctx, *first, true); err != nil {
		t.Fatal(err)
	}
	var count int
	if err = c.pool.QueryRow(ctx, `SELECT count(*) FROM mail_outbox`).Scan(&count); err != nil || count != 1 {
		t.Fatal("stale worker deleted new lease")
	}
	if err = s.FinishMail(ctx, *second, false); err != nil {
		t.Fatal(err)
	}
	encrypted[len(encrypted)-1] ^= 1
	if _, err = c.pool.Exec(ctx, `UPDATE mail_outbox SET encrypted_body=$1,available_at=now()-interval '1 second'`, encrypted); err != nil {
		t.Fatal(err)
	}
	if _, err = s.ClaimMail(ctx); err != service.ErrInvalid {
		t.Fatal("tampered mail decrypted")
	}
}
