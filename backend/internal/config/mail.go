package config

import (
	"encoding/base64"
	"fmt"
	"net"
	"net/mail"
	"strconv"
	"strings"
)

type MailConfig struct {
	Key                               []byte
	Address, From, Username, Password string
	InsecureLocal                     bool
}

func parseMail(get func(string) string, environment string) (MailConfig, error) {
	var c MailConfig
	key := get("MAIL_OUTBOX_KEY")
	c.Address = get("SMTP_ADDR")
	c.From = get("SMTP_FROM")
	c.Username = get("SMTP_USERNAME")
	c.Password = get("SMTP_PASSWORD")
	insecure := get("SMTP_ALLOW_INSECURE_LOCAL")
	if key == "" && c.Address == "" && c.From == "" && c.Username == "" && c.Password == "" && (insecure == "" || insecure == "false") {
		return c, nil
	}
	var err error
	c.Key, err = base64.StdEncoding.DecodeString(key)
	if err != nil || len(c.Key) != 32 {
		return c, fmt.Errorf("MAIL_OUTBOX_KEY must be a base64-encoded 32-byte key")
	}
	host, port, err := net.SplitHostPort(c.Address)
	if err != nil || host == "" {
		return c, fmt.Errorf("SMTP_ADDR must be host:port")
	}
	p, err := strconv.Atoi(port)
	if err != nil || p < 1 || p > 65535 {
		return c, fmt.Errorf("invalid SMTP port")
	}
	address, err := mail.ParseAddress(c.From)
	if err != nil || address.Address != c.From || strings.ContainsAny(c.From, "\r\n") {
		return c, fmt.Errorf("SMTP_FROM must be a single email address")
	}
	if (c.Username == "") != (c.Password == "") {
		return c, fmt.Errorf("SMTP_USERNAME and SMTP_PASSWORD must be set together")
	}
	if insecure != "" && insecure != "true" && insecure != "false" {
		return c, fmt.Errorf("SMTP_ALLOW_INSECURE_LOCAL must be true or false")
	}
	c.InsecureLocal = insecure == "true"
	if c.InsecureLocal && (environment == "production" || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() || c.Username != "") {
		return c, fmt.Errorf("insecure SMTP is allowed only for numeric loopback development/test sinks without credentials")
	}
	return c, nil
}
