package config

import (
	"strings"
	"testing"
	"time"
)

func TestParse(t *testing.T) {
	tests := []struct {
		name      string
		values    map[string]string
		wantError string
	}{
		{"defaults", map[string]string{}, ""},
		{"missing database", map[string]string{"DATABASE_URL": ""}, "DATABASE_URL"},
		{"bad environment", map[string]string{"APP_ENV": "staging"}, "APP_ENV"},
		{"bad port", map[string]string{"HTTP_ADDR": "localhost:65536"}, "HTTP_ADDR"},
		{"bad address", map[string]string{"HTTP_ADDR": ":http"}, "HTTP_ADDR"},
		{"bad pool", map[string]string{"DB_MAX_CONNECTIONS": "0"}, "DB_MAX_CONNECTIONS"},
		{"bad timeout", map[string]string{"DB_TIMEOUT": "0s"}, "DB_TIMEOUT"},
		{"bad shutdown", map[string]string{"SHUTDOWN_TIMEOUT": "2m"}, "SHUTDOWN_TIMEOUT"},
		{"production plaintext", map[string]string{"APP_ENV": "production"}, "sslmode"},
		{"production tls", map[string]string{"APP_ENV": "production", "DATABASE_URL": "postgres://user:secret@db/app?sslmode=verify-full"}, ""},
		{"malformed secret", map[string]string{"DATABASE_URL": "postgres://user:%zzSECRET@db/app"}, "DATABASE_URL"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			env := map[string]string{"DATABASE_URL": "postgres://user:secret@localhost/app?sslmode=disable"}
			for k, v := range tt.values {
				env[k] = v
			}
			c, err := Parse(func(k string) string { return env[k] })
			if tt.wantError != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantError) {
					t.Fatalf("expected %s, got %v", tt.wantError, err)
				}
				if strings.Contains(err.Error(), "SECRET") || strings.Contains(err.Error(), "secret") {
					t.Fatal("secret leaked")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if c.DBTimeout != 3*time.Second || c.MaxConnections != 10 {
				t.Fatalf("unexpected defaults: timeout=%v pool=%d", c.DBTimeout, c.MaxConnections)
			}
		})
	}
}
