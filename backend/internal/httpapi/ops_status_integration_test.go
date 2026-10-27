package httpapi

import (
	"catatuang/backend/internal/opsstatus"
	"context"
	"testing"
	"time"
)

func TestOperationalMailThresholds(t *testing.T) {
	c, _ := recoveryClient(t)
	owner := c.register("ops-thresholds@example.invalid")
	ctx := context.Background()
	c.request("POST", "/v1/auth/password-reset/request", "", map[string]string{"email": owner.User.Email}, nil, 202)
	// One overdue pending message, one future retry, one exhausted job and one
	// expired job. Expired mail must not page an operator as active failure.
	_, err := c.pool.Exec(ctx, `UPDATE mail_outbox SET available_at=clock_timestamp()-interval '10 minutes';
	INSERT INTO mail_outbox(id,user_id,kind,recipient,encrypted_body,expires_at,attempts,available_at)
	SELECT '11111111-1111-4111-8111-111111111111',user_id,kind,recipient,encrypted_body,expires_at,1,clock_timestamp()+interval '1 hour' FROM mail_outbox LIMIT 1;
	INSERT INTO mail_outbox(id,user_id,kind,recipient,encrypted_body,expires_at,attempts)
	SELECT '22222222-2222-4222-8222-222222222222',user_id,kind,recipient,encrypted_body,expires_at,8 FROM mail_outbox LIMIT 1;
	INSERT INTO mail_outbox(id,user_id,kind,recipient,encrypted_body,expires_at,attempts)
	SELECT '33333333-3333-4333-8333-333333333333',user_id,kind,recipient,encrypted_body,clock_timestamp()-interval '1 second',8 FROM mail_outbox LIMIT 1;
	UPDATE sessions SET created_at=clock_timestamp()-interval '2 days',expires_at=clock_timestamp()-interval '1 second'`)
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err := opsstatus.Collect(ctx, c.pool)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Schema != "ready" || snapshot.MailPending != 2 || snapshot.MailFailed != 1 || snapshot.ExpiredSessions != 1 || snapshot.MailOldestAge < 600 || snapshot.MailOldestAge > 620 {
		t.Fatalf("unexpected operational counts: %+v", snapshot)
	}
	if alerts := snapshot.Evaluate(opsstatus.Limits{MaxMailFailed: 0, MaxMailAge: 5 * time.Minute}); len(alerts) != 2 {
		t.Fatalf("missing active alerts: %v", alerts)
	}
	if _, err = c.pool.Exec(ctx, `UPDATE mail_outbox SET attempts=1,available_at=clock_timestamp()+interval '1 hour' WHERE expires_at>clock_timestamp()`); err != nil {
		t.Fatal(err)
	}
	future, err := opsstatus.Collect(ctx, c.pool)
	if err != nil {
		t.Fatal(err)
	}
	if future.MailPending != 3 || future.MailFailed != 0 || future.MailOldestAge != 0 || len(future.Evaluate(opsstatus.Limits{MaxMailFailed: 0, MaxMailAge: time.Second})) != 0 {
		t.Fatalf("future retry incorrectly alerted: %+v", future)
	}
}
