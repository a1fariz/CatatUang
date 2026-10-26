package httpapi

import (
	"bufio"
	"catatuang/backend/internal/config"
	"catatuang/backend/internal/mailer"
	"catatuang/backend/internal/service"
	"context"
	"fmt"
	"io"
	"net"
	"net/mail"
	"net/textproto"
	"regexp"
	"strings"
	"testing"
	"time"
)

// Exercise the transport boundary too: confirmation codes must come from the
// received MIME message, rather than directly from the decrypted outbox.
func TestAccountRecoverySMTPRoundTrip(t *testing.T) {
	c, s := recoveryClient(t)
	owner := c.register("smtp-roundtrip@example.invalid")
	c.request("POST", "/v1/transactions", owner.AccessToken, syncInput(), nil, 201)
	financeBefore := c.request("GET", "/v1/transactions", owner.AccessToken, nil, nil, 200).Body.String()
	address, received := accountSMTPSink(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	deliver := func(subject string) string {
		t.Helper()
		job, err := s.ClaimMail(ctx)
		if err != nil || job == nil {
			t.Fatal("expected queued account email")
		}
		if err = mailer.Send(ctx, config.MailConfig{Address: address, From: "local@example.invalid", InsecureLocal: true}, *job); err != nil {
			t.Fatal(err)
		}
		if err = s.FinishMail(ctx, *job, true); err != nil {
			t.Fatal(err)
		}
		var raw string
		select {
		case raw = <-received:
		case <-ctx.Done():
			t.Fatal("SMTP delivery timed out")
		}
		message, err := mail.ReadMessage(strings.NewReader(raw))
		if err != nil {
			t.Fatal("invalid MIME message")
		}
		if message.Header.Get("To") != owner.User.Email || message.Header.Get("Subject") != subject {
			t.Fatal("incorrect account email recipient or purpose")
		}
		body, err := io.ReadAll(message.Body)
		if err != nil {
			t.Fatal(err)
		}
		token := regexp.MustCompile(`[A-Za-z0-9_-]{43}`).FindString(string(body))
		if token == "" {
			t.Fatal("confirmation code absent from delivered message")
		}
		var pending int
		if err = c.pool.QueryRow(ctx, "SELECT count(*) FROM mail_outbox").Scan(&pending); err != nil || pending != 0 {
			t.Fatal("acknowledged mail remained in outbox")
		}
		return token
	}
	c.request("POST", "/v1/auth/email-verification/request", owner.AccessToken, nil, nil, 202)
	verification := deliver("Catat Uang - kode verifikasi email")
	c.request("POST", "/v1/auth/email-verification/confirm", "", map[string]string{"token": verification}, nil, 204)
	verified := decodeResponse[service.User](t, c.request("GET", "/v1/me", owner.AccessToken, nil, nil, 200))
	if !verified.EmailVerified {
		t.Fatal("delivered verification code did not verify account")
	}
	c.request("POST", "/v1/auth/password-reset/request", "", map[string]string{"email": owner.User.Email}, nil, 202)
	reset := deliver("Catat Uang - kode pemulihan kata sandi")
	input := map[string]string{"token": reset, "new_password": "smtp-reset-passphrase-2026"}
	c.request("POST", "/v1/auth/password-reset/confirm", "", input, nil, 204)
	c.request("POST", "/v1/auth/password-reset/confirm", "", input, nil, 422)
	c.request("GET", "/v1/me", owner.AccessToken, nil, nil, 401)
	c.request("POST", "/v1/auth/login", "", service.Credentials{Email: owner.User.Email, Password: "rahasia-untuk-pengujian-2026"}, nil, 401)
	login := decodeResponse[service.Session](t, c.request("POST", "/v1/auth/login", "", service.Credentials{Email: owner.User.Email, Password: input["new_password"]}, nil, 200))
	if !login.User.EmailVerified {
		t.Fatal("verified account status lost after reset")
	}
	financeAfter := c.request("GET", "/v1/transactions", login.AccessToken, nil, nil, 200).Body.String()
	if financeBefore != financeAfter {
		t.Fatal("account recovery changed financial records")
	}
}

func accountSMTPSink(t *testing.T) (string, <-chan string) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	received := make(chan string, 2)
	t.Cleanup(func() {
		_ = listener.Close()
		select {
		case <-done:
		case <-time.After(6 * time.Second):
			t.Error("SMTP test listener did not stop")
		}
	})
	go func() {
		defer close(done)
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			func() {
				defer conn.Close()
				_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
				reader := textproto.NewReader(bufio.NewReader(conn))
				_, _ = fmt.Fprint(conn, "220 local-test ESMTP\r\n")
				for {
					line, err := reader.ReadLine()
					if err != nil {
						return
					}
					switch {
					case strings.HasPrefix(line, "EHLO "):
						_, _ = fmt.Fprint(conn, "250-local-test\r\n250 8BITMIME\r\n")
					case strings.HasPrefix(line, "MAIL FROM:"), line == "RCPT TO:<smtp-roundtrip@example.invalid>":
						_, _ = fmt.Fprint(conn, "250 OK\r\n")
					case line == "DATA":
						_, _ = fmt.Fprint(conn, "354 data\r\n")
						body, err := reader.ReadDotBytes()
						if err != nil {
							return
						}
						select {
						case received <- string(body):
						default:
							return
						}
						_, _ = fmt.Fprint(conn, "250 queued\r\n")
					case line == "QUIT":
						_, _ = fmt.Fprint(conn, "221 bye\r\n")
						return
					default:
						_, _ = fmt.Fprint(conn, "550 rejected\r\n")
					}
				}
			}()
		}
	}()
	return listener.Addr().String(), received
}
