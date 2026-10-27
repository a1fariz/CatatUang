package opsstatus

import (
	"reflect"
	"testing"
	"time"
)

func TestThresholdBoundaries(t *testing.T) {
	for _, tc := range []struct {
		name string
		s    Snapshot
		l    Limits
		want []string
	}{
		{"disabled", Snapshot{MailPending: 2, MailFailed: 9, MailOldestAge: 999}, Limits{-1, 0}, []string{}},
		{"equal", Snapshot{MailPending: 1, MailFailed: 2, MailOldestAge: 300}, Limits{2, 5 * time.Minute}, []string{}},
		{"both", Snapshot{MailPending: 1, MailFailed: 1, MailOldestAge: 301}, Limits{0, 5 * time.Minute}, []string{"mail_failed_limit_exceeded", "mail_age_limit_exceeded"}},
		{"empty", Snapshot{MailOldestAge: 999}, Limits{0, time.Second}, []string{}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.s.Evaluate(tc.l); !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("alerts=%v want=%v", got, tc.want)
			}
		})
	}
	for _, limits := range []Limits{{-2, 0}, {0, -time.Second}} {
		if limits.Validate() == nil {
			t.Fatal("invalid limits accepted")
		}
	}
}
