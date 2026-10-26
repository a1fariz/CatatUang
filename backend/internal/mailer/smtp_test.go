package mailer

import (
	"bufio"
	"catatuang/backend/internal/config"
	"catatuang/backend/internal/service"
	"context"
	"fmt"
	"net"
	"strings"
	"testing"
	"time"
)

func smtpSink(t *testing.T) (string, <-chan string) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	delivered := make(chan string, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
		reader := bufio.NewReader(conn)
		_, _ = fmt.Fprint(conn, "220 local-test ESMTP\r\n")
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				return
			}
			switch {
			case strings.HasPrefix(line, "EHLO"):
				_, _ = fmt.Fprint(conn, "250-local-test\r\n250 8BITMIME\r\n")
			case strings.HasPrefix(line, "MAIL FROM:"), strings.HasPrefix(line, "RCPT TO:"):
				_, _ = fmt.Fprint(conn, "250 OK\r\n")
			case line == "DATA\r\n":
				_, _ = fmt.Fprint(conn, "354 data\r\n")
				var body strings.Builder
				for {
					part, err := reader.ReadString('\n')
					if err != nil {
						return
					}
					if part == ".\r\n" {
						break
					}
					body.WriteString(part)
				}
				delivered <- body.String()
				_, _ = fmt.Fprint(conn, "250 queued\r\n")
			case line == "QUIT\r\n":
				_, _ = fmt.Fprint(conn, "221 bye\r\n")
				return
			default:
				_, _ = fmt.Fprint(conn, "500 unsupported\r\n")
			}
		}
	}()
	return listener.Addr().String(), delivered
}
func TestSMTPDeliversOnlyToExplicitLocalSink(t *testing.T) {
	address, delivered := smtpSink(t)
	config := config.MailConfig{Address: address, From: "noreply@example.com", InsecureLocal: true}
	message := service.PendingMail{ID: service.NewID(), Recipient: "owner@example.com", Kind: "verify", Body: "Kode pengujian saja\r\n"}
	if err := Send(context.Background(), config, message); err != nil {
		t.Fatal(err)
	}
	select {
	case body := <-delivered:
		if !strings.Contains(body, "To: owner@example.com\r\n") || !strings.Contains(body, message.Body) {
			t.Fatal("incomplete SMTP message")
		}
	case <-time.After(time.Second):
		t.Fatal("message not delivered")
	}
}
func TestSMTPRefusesMissingTLSAndHeaderInjection(t *testing.T) {
	address, delivered := smtpSink(t)
	message := service.PendingMail{ID: service.NewID(), Recipient: "owner@example.com", Kind: "reset", Body: "secret"}
	if err := Send(context.Background(), config.MailConfig{Address: address, From: "noreply@example.com"}, message); err == nil {
		t.Fatal("plaintext delivery allowed")
	}
	select {
	case <-delivered:
		t.Fatal("secret sent without TLS")
	default:
	}
	message.Recipient = "owner@example.com\r\nBcc: other@example.com"
	if err := Send(context.Background(), config.MailConfig{Address: address, From: "noreply@example.com", InsecureLocal: true}, message); err == nil {
		t.Fatal("header injection allowed")
	}
}
