package config

import (
	"fmt"
	"net"
	"net/netip"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Environment     string
	Address         string
	DatabaseURL     string
	MaxConnections  int32
	DBTimeout       time.Duration
	ShutdownTimeout time.Duration
	Mail            MailConfig
	TrustedProxies  []netip.Prefix
}

func Load() (Config, error) { return Parse(os.Getenv) }

func Parse(get func(string) string) (Config, error) {
	c := Config{Environment: get("APP_ENV"), Address: get("HTTP_ADDR"), DatabaseURL: get("DATABASE_URL"), MaxConnections: 10, DBTimeout: 3 * time.Second, ShutdownTimeout: 10 * time.Second}
	if c.Environment == "" {
		c.Environment = "development"
	}
	if c.Environment != "development" && c.Environment != "test" && c.Environment != "production" {
		return c, fmt.Errorf("APP_ENV must be development, test, or production")
	}
	if c.Address == "" {
		c.Address = "127.0.0.1:8080"
	}
	_, port, err := net.SplitHostPort(c.Address)
	if err != nil {
		return c, fmt.Errorf("HTTP_ADDR must be host:port")
	}
	p, err := strconv.Atoi(port)
	if err != nil || p < 1 || p > 65535 {
		return c, fmt.Errorf("HTTP_ADDR port must be between 1 and 65535")
	}
	u, err := url.Parse(c.DatabaseURL)
	if err != nil || u == nil || (u.Scheme != "postgres" && u.Scheme != "postgresql") || u.Hostname() == "" || u.Path == "" || u.Path == "/" || u.User == nil || u.User.Username() == "" {
		return c, fmt.Errorf("DATABASE_URL must be a PostgreSQL URL with host, user, and database")
	}
	if c.Environment == "production" && u.Query().Get("sslmode") != "verify-full" {
		return c, fmt.Errorf("production DATABASE_URL requires sslmode=verify-full")
	}
	if raw := get("DB_MAX_CONNECTIONS"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 || n > 100 {
			return c, fmt.Errorf("DB_MAX_CONNECTIONS must be between 1 and 100")
		}
		c.MaxConnections = int32(n)
	}
	for _, item := range []struct {
		key    string
		target *time.Duration
	}{{"DB_TIMEOUT", &c.DBTimeout}, {"SHUTDOWN_TIMEOUT", &c.ShutdownTimeout}} {
		if raw := get(item.key); raw != "" {
			d, err := time.ParseDuration(raw)
			if err != nil || d < time.Second || d > time.Minute {
				return c, fmt.Errorf("%s must be between 1s and 1m", item.key)
			}
			*item.target = d
		}
	}
	c.Mail, err = parseMail(get, c.Environment)
	if err != nil {
		return c, err
	}
	if raw := get("TRUSTED_PROXY_CIDRS"); raw != "" {
		parts := strings.Split(raw, ",")
		if len(parts) > 32 {
			return c, fmt.Errorf("too many trusted proxy CIDRs")
		}
		for _, part := range parts {
			prefix, parseErr := netip.ParsePrefix(strings.TrimSpace(part))
			if parseErr != nil || prefix.Bits() == 0 {
				return c, fmt.Errorf("TRUSTED_PROXY_CIDRS requires explicit non-default CIDR ranges")
			}
			c.TrustedProxies = append(c.TrustedProxies, prefix.Masked())
		}
	}
	return c, nil
}
