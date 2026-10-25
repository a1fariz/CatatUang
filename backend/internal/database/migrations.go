package database

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"
	"strings"

	"catatuang/backend/migrations"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var ErrSchemaNotCurrent = errors.New("database schema is not current; run migrations")

type Migration struct{ Name, SQL, Checksum string }

func BundledMigrations() ([]Migration, error) {
	names, err := migrations.Files.ReadDir(".")
	if err != nil {
		return nil, err
	}
	var result []Migration
	for _, entry := range names {
		if !strings.HasSuffix(entry.Name(), ".sql") {
			continue
		}
		body, err := migrations.Files.ReadFile(entry.Name())
		if err != nil {
			return nil, err
		}
		sum := sha256.Sum256(body)
		result = append(result, Migration{Name: entry.Name(), SQL: string(body), Checksum: hex.EncodeToString(sum[:])})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result, nil
}

func Migrate(ctx context.Context, pool *pgxpool.Pool) (int, error) {
	files, err := BundledMigrations()
	if err != nil {
		return 0, err
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(context.Background())
	if _, err := tx.Exec(ctx, "SET LOCAL statement_timeout = '55s'; SET LOCAL lock_timeout = '10s'"); err != nil {
		return 0, err
	}
	// Transaction-scoped lock serializes concurrent migration processes.
	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(1128354881)"); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
   name TEXT PRIMARY KEY, checksum TEXT NOT NULL, applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
 )`); err != nil {
		return 0, err
	}
	applied, err := readApplied(ctx, tx)
	if err != nil {
		return 0, err
	}
	if err := verifyHistory(files, applied); err != nil {
		return 0, err
	}
	count := 0
	for _, file := range files {
		if _, ok := applied[file.Name]; ok {
			continue
		}
		if _, err := tx.Exec(ctx, file.SQL); err != nil {
			return 0, fmt.Errorf("migration %s failed: %w", file.Name, err)
		}
		if _, err := tx.Exec(ctx, "INSERT INTO schema_migrations(name,checksum) VALUES($1,$2)", file.Name, file.Checksum); err != nil {
			return 0, err
		}
		count++
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return count, nil
}

type queryer interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
}

func readApplied(ctx context.Context, q queryer) (map[string]string, error) {
	rows, err := q.Query(ctx, "SELECT name,checksum FROM schema_migrations ORDER BY name")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	applied := map[string]string{}
	for rows.Next() {
		var name, sum string
		if err := rows.Scan(&name, &sum); err != nil {
			return nil, err
		}
		applied[name] = sum
	}
	return applied, rows.Err()
}

func verifyHistory(files []Migration, applied map[string]string) error {
	known := map[string]string{}
	for _, file := range files {
		known[file.Name] = file.Checksum
	}
	for name, sum := range applied {
		if known[name] != sum {
			return fmt.Errorf("migration history mismatch: %s", name)
		}
	}
	missing := false
	for _, file := range files {
		if _, ok := applied[file.Name]; !ok {
			missing = true
		} else if missing {
			return fmt.Errorf("migration history contains a gap before %s", file.Name)
		}
	}
	return nil
}

// CheckSchema is read-only: API startup never runs DDL or applies migrations.
func CheckSchema(ctx context.Context, pool *pgxpool.Pool) error {
	var exists bool
	if err := pool.QueryRow(ctx, "SELECT to_regclass('public.schema_migrations') IS NOT NULL").Scan(&exists); err != nil {
		return err
	}
	if !exists {
		return ErrSchemaNotCurrent
	}
	applied, err := readApplied(ctx, pool)
	if err != nil {
		return err
	}
	files, err := BundledMigrations()
	if err != nil {
		return err
	}
	if err := verifyHistory(files, applied); err != nil {
		return err
	}
	if len(files) != len(applied) {
		return ErrSchemaNotCurrent
	}
	return nil
}
