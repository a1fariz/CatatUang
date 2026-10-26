package database

import (
	"context"
	"testing"
	"time"
)

func TestSessionIDMigrationPreservesExistingCredentials(t *testing.T) {
	pool := testPool(t)
	ctx := context.Background()
	files, err := BundledMigrations()
	if err != nil {
		t.Fatal(err)
	}
	if _, err = pool.Exec(ctx, `CREATE TABLE schema_migrations(name TEXT PRIMARY KEY,checksum TEXT NOT NULL,applied_at TIMESTAMPTZ NOT NULL DEFAULT now())`); err != nil {
		t.Fatal(err)
	}
	for _, file := range files {
		if file.Name >= "000005_session_ids.sql" {
			break
		}
		if _, err = pool.Exec(ctx, file.SQL); err != nil {
			t.Fatal(err)
		}
		if _, err = pool.Exec(ctx, `INSERT INTO schema_migrations(name,checksum) VALUES($1,$2)`, file.Name, file.Checksum); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = pool.Exec(ctx, `INSERT INTO users(id,email,password_hash) VALUES('11111111-1111-4111-8111-111111111111','legacy-session@example.com','fixture-hash'); INSERT INTO sessions(token_hash,user_id,created_at,expires_at) VALUES(decode(repeat('ab',32),'hex'),'11111111-1111-4111-8111-111111111111','2026-10-26T00:00:00Z','2026-10-27T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if _, err = Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	var id, hash string
	var created, expires time.Time
	if err = pool.QueryRow(ctx, `SELECT id::text,encode(token_hash,'hex'),created_at,expires_at FROM sessions`).Scan(&id, &hash, &created, &expires); err != nil {
		t.Fatal(err)
	}
	if len(id) != 36 || hash != "abababababababababababababababababababababababababababababababab" || created.UTC().Format(time.RFC3339) != "2026-10-26T00:00:00Z" || expires.UTC().Format(time.RFC3339) != "2026-10-27T00:00:00Z" {
		t.Fatal("session credentials or lifetime changed during upgrade")
	}
}
