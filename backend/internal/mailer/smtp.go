package mailer

import (
	"catatuang/backend/internal/config"
	"catatuang/backend/internal/service"
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/mail"
	"net/smtp"
	"strings"
	"time"
)

func Send(ctx context.Context, c config.MailConfig, message service.PendingMail) error {
	to, err := mail.ParseAddress(message.Recipient)
	if err != nil || to.Address != message.Recipient || strings.ContainsAny(message.Recipient, "\r\n") {
		return fmt.Errorf("invalid recipient")
	}
	host, _, err := net.SplitHostPort(c.Address)
	if err != nil {
		return fmt.Errorf("invalid SMTP address")
	}
	// Also enforce the local exception here for callers constructing config.
	if c.InsecureLocal && (net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() || c.Username != "") {
		return fmt.Errorf("insecure SMTP must use numeric loopback without authentication")
	}
	conn, err := (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, "tcp", c.Address)
	if err != nil {
		return fmt.Errorf("SMTP connection failed")
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
	client, err := smtp.NewClient(conn, host)
	if err != nil {
		return fmt.Errorf("SMTP greeting failed")
	}
	defer client.Close()
	if !c.InsecureLocal {
		if ok, _ := client.Extension("STARTTLS"); !ok {
			return fmt.Errorf("SMTP requires STARTTLS")
		}
		if err = client.StartTLS(&tls.Config{ServerName: host, MinVersion: tls.VersionTLS12}); err != nil {
			return fmt.Errorf("SMTP TLS failed")
		}
	}
	if c.Username != "" {
		if err = client.Auth(smtp.PlainAuth("", c.Username, c.Password, host)); err != nil {
			return fmt.Errorf("SMTP authentication failed")
		}
	}
	if err = client.Mail(c.From); err != nil {
		return fmt.Errorf("SMTP sender rejected")
	}
	if err = client.Rcpt(message.Recipient); err != nil {
		return fmt.Errorf("SMTP recipient rejected")
	}
	writer, err := client.Data()
	if err != nil {
		return fmt.Errorf("SMTP DATA rejected")
	}
	subject := "Catat Uang - kode pemulihan kata sandi"
	if message.Kind == "verify" {
		subject = "Catat Uang - kode verifikasi email"
	}
	_, err = fmt.Fprintf(writer, "From: %s\r\nTo: %s\r\nSubject: %s\r\nDate: %s\r\nMessage-ID: <%s@catatuang.invalid>\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n%s", c.From, message.Recipient, subject, time.Now().UTC().Format(time.RFC1123Z), message.ID, message.Body)
	if err != nil {
		_ = writer.Close()
		return fmt.Errorf("SMTP body write failed")
	}
	if err = writer.Close(); err != nil {
		return fmt.Errorf("SMTP delivery unconfirmed")
	}
	// DATA success is authoritative; a lost QUIT response must not resend.
	_ = client.Quit()
	return nil
}
