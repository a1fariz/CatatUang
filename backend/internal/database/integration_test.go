package database

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"sync"
	"testing"
	"time"

	"catatuang/backend/internal/config"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Each test creates its own database. The configured role must have CREATEDB.
func testPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	raw := os.Getenv("TEST_DATABASE_URL")
	if raw == "" {
		t.Skip("set TEST_DATABASE_URL to run PostgreSQL integration tests")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	admin, err := pgx.Connect(ctx, raw)
	if err != nil {
		t.Fatal("cannot connect to integration database")
	}
	name := fmt.Sprintf("catatuang_test_%d", time.Now().UnixNano())
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+pgx.Identifier{name}.Sanitize()); err != nil {
		admin.Close(ctx)
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if _, err := admin.Exec(ctx, "DROP DATABASE "+pgx.Identifier{name}.Sanitize()+" WITH (FORCE)"); err != nil {
			t.Error(err)
		}
		_ = admin.Close(ctx)
	})
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal("invalid TEST_DATABASE_URL")
	}
	u.Path = "/" + name
	pool, err := Open(ctx, config.Config{DatabaseURL: u.String(), MaxConnections: 5, DBTimeout: 3 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool
}

func TestPostgresMigrationLifecycle(t *testing.T) {
	pool := testPool(t)
	ctx := context.Background()
	if err := CheckSchema(ctx, pool); err == nil {
		t.Fatal("fresh database reported ready")
	}
	var wg sync.WaitGroup
	results := make(chan int, 2)
	errs := make(chan error, 2)
	for range 2 {
		wg.Add(1)
		go func() { defer wg.Done(); n, err := Migrate(ctx, pool); results <- n; errs <- err }()
	}
	wg.Wait()
	close(results)
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	total := 0
	for n := range results {
		total += n
	}
	files, _ := BundledMigrations()
	if total != len(files) {
		t.Fatalf("migration applied %d times", total)
	}
	if err := CheckSchema(ctx, pool); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, "UPDATE schema_migrations SET checksum = 'tampered'"); err != nil {
		t.Fatal(err)
	}
	if err := CheckSchema(ctx, pool); err == nil {
		t.Fatal("checksum tamper accepted")
	}
	if _, err := Migrate(ctx, pool); err == nil {
		t.Fatal("migration accepted modified history")
	}
}

func TestPostgresMigrationRollback(t *testing.T) {
	pool := testPool(t)
	ctx := context.Background()
	if _, err := pool.Exec(ctx, "CREATE TABLE users (id integer)"); err != nil {
		t.Fatal(err)
	}
	if _, err := Migrate(ctx, pool); err == nil {
		t.Fatal("expected conflicting table failure")
	}
	var exists bool
	if err := pool.QueryRow(ctx, "SELECT to_regclass('public.schema_migrations') IS NOT NULL").Scan(&exists); err != nil {
		t.Fatal(err)
	}
	if exists {
		t.Fatal("failed migration left partial metadata")
	}
	if _, err := pool.Exec(ctx, "DROP TABLE users"); err != nil {
		t.Fatal(err)
	}
	if _, err := Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
}

func TestPostgresUpgradePreservesFinanceData(t *testing.T) {
	pool := testPool(t)
	ctx := context.Background()
	files, err := BundledMigrations()
	if err != nil {
		t.Fatal(err)
	}
	if _, err = pool.Exec(ctx, `CREATE TABLE schema_migrations(name TEXT PRIMARY KEY,checksum TEXT NOT NULL,applied_at TIMESTAMPTZ NOT NULL DEFAULT now())`); err != nil {
		t.Fatal(err)
	}
	if _, err = pool.Exec(ctx, files[0].SQL); err != nil {
		t.Fatal(err)
	}
	if _, err = pool.Exec(ctx, "INSERT INTO schema_migrations(name,checksum) VALUES($1,$2)", files[0].Name, files[0].Checksum); err != nil {
		t.Fatal(err)
	}
	if _, err = pool.Exec(ctx, `INSERT INTO users(id,email,password_hash) VALUES('11111111-1111-4111-8111-111111111111','existing@example.invalid','existing-hash');
  INSERT INTO transactions(id,user_id,type,amount_minor,currency_code,category,occurred_on) VALUES('33333333-3333-4333-8333-333333333333','11111111-1111-4111-8111-111111111111','expense',42000,'IDR','Makan','2026-10-25');
  INSERT INTO transactions(id,user_id,type,amount_minor,currency_code,category,occurred_on,deleted_at) VALUES('44444444-4444-4444-8444-444444444444','11111111-1111-4111-8111-111111111111','expense',1000,'IDR','Makan','2026-10-25',now())`); err != nil {
		t.Fatal(err)
	}
	count, err := Migrate(ctx, pool)
	if err != nil || count != len(files)-1 {
		t.Fatal("upgrade failed", count, err)
	}
	var amount int64
	if err = pool.QueryRow(ctx, "SELECT amount_minor FROM transactions WHERE id='33333333-3333-4333-8333-333333333333'").Scan(&amount); err != nil || amount != 42000 {
		t.Fatal("existing finance data changed", err)
	}
	if err = CheckSchema(ctx, pool); err != nil {
		t.Fatal(err)
	}
	var baselineAmount, baselineVersion, clock int64
	var baselineDeleted bool
	if err = pool.QueryRow(ctx, `SELECT (record->>'amount_minor')::bigint,(record->>'version')::bigint,(record->>'deleted')::boolean,seq FROM transaction_changes WHERE record->>'id'='33333333-3333-4333-8333-333333333333'`).Scan(&baselineAmount, &baselineVersion, &baselineDeleted, &clock); err != nil || baselineAmount != 42000 || baselineVersion != 1 || baselineDeleted || clock != 1 {
		t.Fatal("sync migration did not backfill existing transaction", err)
	}
	if err = pool.QueryRow(ctx, `SELECT seq FROM transaction_sync_clock WHERE user_id='11111111-1111-4111-8111-111111111111'`).Scan(&clock); err != nil || clock != 2 {
		t.Fatal("sync migration did not seed clock", err)
	}
	if err = pool.QueryRow(ctx, `SELECT (record->>'deleted')::boolean FROM transaction_changes WHERE seq=2`).Scan(&baselineDeleted); err != nil || !baselineDeleted {
		t.Fatal("sync migration lost existing tombstone", err)
	}
}

func TestPostgresDomainConstraints(t *testing.T) {
	pool := testPool(t)
	ctx := context.Background()
	if _, err := Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	const owner = "11111111-1111-4111-8111-111111111111"
	const other = "22222222-2222-4222-8222-222222222222"
	const transaction = "33333333-3333-4333-8333-333333333333"
	const bill = "44444444-4444-4444-8444-444444444444"
	for i, id := range []string{owner, other} {
		if _, err := pool.Exec(ctx, "INSERT INTO users(id,email,password_hash) VALUES($1,$2,$3)", id, fmt.Sprintf("test%d@example.invalid", i), "test-hash-not-for-login"); err != nil {
			t.Fatal(err)
		}
	}
	insert := `INSERT INTO transactions(id,user_id,type,amount_minor,currency_code,category,occurred_on) VALUES($1,$2,'expense',$3,'IDR','Makan','2026-10-25')`
	if _, err := pool.Exec(ctx, insert, transaction, owner, 0); err == nil {
		t.Fatal("zero amount accepted")
	}
	if _, err := pool.Exec(ctx, insert, transaction, owner, 42000); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, "UPDATE transactions SET note='changed',version=100 WHERE id=$1", transaction); err != nil {
		t.Fatal(err)
	}
	var version int64
	var date string
	if err := pool.QueryRow(ctx, "SELECT version,occurred_on::text FROM transactions WHERE id=$1", transaction).Scan(&version, &date); err != nil {
		t.Fatal(err)
	}
	if version != 2 || date != "2026-10-25" {
		t.Fatalf("bad version/date: %d %s", version, date)
	}
	if _, err := pool.Exec(ctx, "UPDATE transactions SET user_id=$1 WHERE id=$2", other, transaction); err == nil {
		t.Fatal("ownership transfer accepted")
	}
	if _, err := pool.Exec(ctx, `INSERT INTO bills(id,user_id,name,amount_minor,currency_code,due_at,timezone,recurrence,recurrence_day) VALUES($1,$2,'Internet',1000,'IDR','2030-01-31 09:00:00+07','Asia/Jakarta','monthly',31)`, bill, owner); err != nil {
		t.Fatal(err)
	}
	payment := `INSERT INTO bill_payments(id,user_id,bill_id,due_at,amount_minor,currency_code,paid_at) VALUES($1,$2,$3,'2030-01-31 09:00:00+07',1000,'IDR',now())`
	if _, err := pool.Exec(ctx, payment, "55555555-5555-4555-8555-555555555555", other, bill); err == nil {
		t.Fatal("cross-user payment accepted")
	}
	if _, err := pool.Exec(ctx, payment, "55555555-5555-4555-8555-555555555555", owner, bill); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, payment, "66666666-6666-4666-8666-666666666666", owner, bill); err == nil {
		t.Fatal("duplicate bill occurrence payment accepted")
	}
	if _, err := pool.Exec(ctx, "UPDATE bills SET status='paid' WHERE id=$1", bill); err == nil {
		t.Fatal("paid status without timestamp accepted")
	}
	if _, err := pool.Exec(ctx, "UPDATE transactions SET deleted_at=now() WHERE id=$1", transaction); err != nil {
		t.Fatal(err)
	}
	var deleted bool
	if err := pool.QueryRow(ctx, "SELECT deleted_at IS NOT NULL AND version=3 FROM transactions WHERE id=$1", transaction).Scan(&deleted); err != nil || !deleted {
		t.Fatal("soft deletion/version failed", err)
	}
}
