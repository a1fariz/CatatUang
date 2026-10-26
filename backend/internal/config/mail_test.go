package config

import (
	"encoding/base64"
	"testing"
)

func TestMailConfiguration(t *testing.T) {
	key := base64.StdEncoding.EncodeToString(make([]byte, 32))
	cases := []struct {
		name, environment, host, insecure, username string
		valid                                       bool
	}{
		{"local sink", "test", "127.0.0.1:1025", "true", "", true},
		{"TLS provider", "production", "smtp.example.com:587", "false", "user", true},
		{"remote plaintext", "development", "smtp.example.com:25", "true", "", false},
		{"production plaintext", "production", "127.0.0.1:25", "true", "", false},
		{"DNS local exception", "test", "localhost:1025", "true", "", false},
		{"local credentials plaintext", "test", "127.0.0.1:25", "true", "user", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			env := map[string]string{"MAIL_OUTBOX_KEY": key, "SMTP_ADDR": tc.host, "SMTP_FROM": "noreply@example.com", "SMTP_ALLOW_INSECURE_LOCAL": tc.insecure, "SMTP_USERNAME": tc.username}
			if tc.username != "" {
				env["SMTP_PASSWORD"] = "test-password"
			}
			_, err := parseMail(func(k string) string { return env[k] }, tc.environment)
			if (err == nil) != tc.valid {
				t.Fatalf("unexpected configuration result: %v", err)
			}
		})
	}
}
