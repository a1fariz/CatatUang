package httpapi

import (
	"bytes"
	"catatuang/backend/internal/database"
	"catatuang/backend/internal/pgtools"
	"catatuang/backend/internal/service"
	"context"
	"encoding/json"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRestrictedRuntimeAndMailRoles(t *testing.T) {
	c := integrationClient(t)
	ctx := context.Background()
	suffix := strings.ReplaceAll(service.NewID(), "-", "")
	runtimeRole, mailRole := "catatuang_runtime_"+suffix, "catatuang_mail_"+suffix
	for _, role := range []string{runtimeRole, mailRole} {
		if _, err := c.pool.Exec(ctx, "CREATE ROLE "+pgx.Identifier{role}.Sanitize()+" NOLOGIN NOINHERIT"); err != nil {
			t.Fatal(err)
		}
	}
	defer func() {
		for _, role := range []string{runtimeRole, mailRole} {
			_, _ = c.pool.Exec(ctx, "DROP OWNED BY "+pgx.Identifier{role}.Sanitize())
			if _, err := c.pool.Exec(ctx, "DROP ROLE "+pgx.Identifier{role}.Sanitize()); err != nil {
				t.Error(err)
			}
		}
	}()
	script, err := os.ReadFile("../../deploy/roles.sql")
	if err != nil {
		t.Fatal(err)
	}
	sql := strings.ReplaceAll(strings.ReplaceAll(string(script), "catatuang_runtime", runtimeRole), "catatuang_mail", mailRole)
	if _, err = c.pool.Exec(ctx, sql); err != nil {
		t.Fatal(err)
	}
	rolePool := func(role string) *pgxpool.Pool {
		cfg := c.pool.Config().Copy()
		cfg.AfterConnect = func(ctx context.Context, conn *pgx.Conn) error {
			_, err := conn.Exec(ctx, "SET ROLE "+pgx.Identifier{role}.Sanitize())
			return err
		}
		pool, err := pgxpool.NewWithConfig(ctx, cfg)
		if err != nil {
			t.Fatal(err)
		}
		return pool
	}
	runtime := rolePool(runtimeRole)
	defer runtime.Close()
	worker := rolePool(mailRole)
	defer worker.Close()
	if err = database.CheckSchema(ctx, runtime); err != nil {
		t.Fatal(err)
	}
	if err = database.CheckSchema(ctx, worker); err != nil {
		t.Fatal(err)
	}
	app := service.New(runtime)
	if err = app.ConfigureMail(bytes.Repeat([]byte{9}, 32)); err != nil {
		t.Fatal(err)
	}
	owner, err := app.Authenticate(ctx, service.Credentials{Email: "least-privilege@example.com", Password: originalPassword}, true)
	if err != nil {
		t.Fatal(err)
	}
	dataset, err := app.SyncDataset(ctx)
	if err != nil {
		t.Fatal(err)
	}
	payload := syncInput()
	if _, err = app.PushTransaction(ctx, owner.User.ID, service.SyncMutation{OperationID: service.NewID(), ID: service.NewID(), Payload: &payload}, dataset); err != nil {
		t.Fatal("runtime sync grant missing", err)
	}
	due := time.Date(2026, 10, 26, 1, 0, 0, 0, time.UTC)
	bill, err := app.SaveBill(ctx, owner.User.ID, "", 0, service.BillInput{Name: "Internet", AmountMinor: 1, CurrencyCode: "IDR", DueAt: due, Timezone: "Asia/Jakarta", Recurrence: "monthly", RecurrenceDay: 26})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = app.PayBill(ctx, owner.User.ID, bill.ID, service.NewID(), bill.Version, due); err != nil {
		t.Fatal("runtime payment grant missing", err)
	}
	if err = app.RequestPasswordReset(ctx, owner.User.Email); err != nil {
		t.Fatal(err)
	}
	mailService := service.New(worker)
	if err = mailService.ConfigureMail(bytes.Repeat([]byte{9}, 32)); err != nil {
		t.Fatal(err)
	}
	message, err := mailService.ClaimMail(ctx)
	if err != nil || message == nil {
		t.Fatal("mail role cannot claim", err)
	}
	if err = mailService.FinishMail(ctx, *message, true); err != nil {
		t.Fatal(err)
	}
	for _, query := range []string{`CREATE TABLE forbidden(id int)`, `UPDATE sync_dataset SET dataset_id=gen_random_uuid()`, `DELETE FROM transactions`, `UPDATE schema_migrations SET checksum='bad'`} {
		if _, err = runtime.Exec(ctx, query); err == nil {
			t.Fatal("runtime privilege too broad")
		}
	}
	if _, err = worker.Exec(ctx, `SELECT password_hash FROM users`); err == nil {
		t.Fatal("mail role read account hashes")
	}
	if err = app.ChangePassword(ctx, owner.User.ID, owner.AccessToken, service.PasswordChange{CurrentPassword: originalPassword, NewPassword: replacementPassword}); err != nil {
		t.Fatal("runtime session lock grant missing", err)
	}
}

func TestServerBackupAndIsolatedRestore(t *testing.T) {
	binary := os.Getenv("RESTORE_CHECK_EXE")
	pgBin := os.Getenv("PG_TEST_BIN")
	if binary == "" {
		t.Skip("set RESTORE_CHECK_EXE and PG_TEST_BIN for native backup restore rehearsal")
	}
	c := integrationClient(t)
	owner := c.register("backup@example.com")
	ctx := context.Background()
	p := syncInput()
	c.push(owner.AccessToken, service.SyncMutation{OperationID: service.NewID(), ID: service.NewID(), Payload: &p}, 200)
	due := time.Date(2026, 10, 26, 1, 0, 0, 0, time.UTC)
	bill := decodeResponse[service.Bill](t, c.request("POST", "/v1/bills", owner.AccessToken, service.BillInput{Name: "Listrik", AmountMinor: 100000, CurrencyCode: "IDR", DueAt: due, Timezone: "Asia/Jakarta", Recurrence: "once", RecurrenceDay: 26}, nil, 201))
	c.request("POST", "/v1/bills/"+bill.ID+"/pay", owner.AccessToken, map[string]any{"due_at": due}, map[string]string{"If-Match": `"1"`, "Idempotency-Key": service.NewID()}, 200)
	destination := filepath.Join(t.TempDir(), "ledger.dump")
	raw := c.pool.Config().ConnString()
	if _, err := pgtools.Backup(ctx, raw, pgBin, destination); err != nil {
		t.Fatal(err)
	}
	if err := pgtools.Verify(destination); err != nil {
		t.Fatal(err)
	}
	if _, err := pgtools.Backup(ctx, raw, pgBin, destination); err == nil {
		t.Fatal("backup overwrote existing file")
	}
	command := exec.Command(binary, "-in", destination, "-pg-bin", pgBin)
	for _, item := range os.Environ() {
		key, _, _ := strings.Cut(item, "=")
		if key != "DATABASE_URL" && key != "APP_ENV" && !strings.HasPrefix(key, "MAIL_") && !strings.HasPrefix(key, "SMTP_") {
			command.Env = append(command.Env, item)
		}
	}
	command.Env = append(command.Env, "DATABASE_URL="+raw, "APP_ENV=test")
	output, err := command.Output()
	if err != nil {
		t.Fatal("isolated restore failed")
	}
	var result struct {
		Transactions, Bills, Payments int
		SecurityReset                 bool `json:"security_reset_rehearsed"`
	}
	if json.Unmarshal(output, &result) != nil || result.Transactions != 1 || result.Bills != 1 || result.Payments != 1 || !result.SecurityReset {
		t.Fatal("restore finance differs")
	}
	c.request("GET", "/v1/me", owner.AccessToken, nil, nil, 200)
	file, err := os.OpenFile(destination, os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = file.Write([]byte("tamper"))
	_ = file.Close()
	if err = pgtools.Verify(destination); err == nil {
		t.Fatal("tampered dump passed checksum")
	}
}
