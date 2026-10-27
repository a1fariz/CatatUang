package opsstatus

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Snapshot struct {
	Schema          string   `json:"schema"`
	MailPending     int64    `json:"mail_pending"`
	MailFailed      int64    `json:"mail_failed"`
	MailOldestAge   float64  `json:"mail_oldest_available_age_seconds"`
	ExpiredSessions int64    `json:"expired_sessions"`
	PoolAcquired    int32    `json:"pool_acquired"`
	PoolTotal       int32    `json:"pool_total"`
	Alerts          []string `json:"alerts"`
}

type Limits struct {
	MaxMailFailed int64
	MaxMailAge    time.Duration
}

func (l Limits) Validate() error {
	if l.MaxMailFailed < -1 || l.MaxMailAge < 0 {
		return fmt.Errorf("max-mail-failed must be -1 or greater; max-mail-age must be nonnegative")
	}
	return nil
}

// Alerts contain stable identifiers only, never mail contents or recipients.
// Equality is accepted; a limit is breached only when a value exceeds it.
func (s Snapshot) Evaluate(l Limits) []string {
	alerts := []string{}
	if l.MaxMailFailed >= 0 && s.MailFailed > l.MaxMailFailed {
		alerts = append(alerts, "mail_failed_limit_exceeded")
	}
	if l.MaxMailAge > 0 && s.MailPending > 0 && s.MailOldestAge > l.MaxMailAge.Seconds() {
		alerts = append(alerts, "mail_age_limit_exceeded")
	}
	return alerts
}

func Collect(ctx context.Context, pool *pgxpool.Pool) (Snapshot, error) {
	s := Snapshot{Schema: "ready", Alerts: []string{}}
	err := pool.QueryRow(ctx, `SELECT count(*) FILTER(WHERE expires_at>clock_timestamp() AND attempts<8),count(*) FILTER(WHERE expires_at>clock_timestamp() AND attempts>=8),COALESCE(EXTRACT(EPOCH FROM clock_timestamp()-min(available_at) FILTER(WHERE expires_at>clock_timestamp() AND attempts<8)),0),(SELECT count(*) FROM sessions WHERE expires_at<=clock_timestamp()) FROM mail_outbox`).Scan(&s.MailPending, &s.MailFailed, &s.MailOldestAge, &s.ExpiredSessions)
	if err != nil {
		return Snapshot{}, err
	}
	if s.MailOldestAge < 0 {
		s.MailOldestAge = 0
	}
	s.PoolAcquired = pool.Stat().AcquiredConns()
	s.PoolTotal = pool.Stat().TotalConns()
	return s, nil
}
