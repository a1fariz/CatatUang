package main

import (
	"catatuang/backend/internal/config"
	"catatuang/backend/internal/database"
	"catatuang/backend/internal/pgtools"
	"catatuang/backend/internal/service"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"github.com/jackc/pgx/v5"
	"io"
	"net/url"
	"os"
	"strings"
	"time"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run() (result error) {
	input := flag.String("in", "", "Backup dump path with checksum manifest")
	bin := flag.String("pg-bin", "", "PostgreSQL 18 bin directory")
	flag.Parse()
	if *input == "" || flag.NArg() != 0 {
		return errors.New("usage: restore-check -in backup.dump [-pg-bin directory]")
	}
	if err := pgtools.Verify(*input); err != nil {
		return err
	}
	c, err := config.Load()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	admin, err := pgx.Connect(ctx, c.DatabaseURL)
	if err != nil {
		return errors.New("restore-check admin connection failed")
	}
	defer admin.Close(context.Background())
	name := "catatuang_restorecheck_" + strings.ReplaceAll(service.NewID(), "-", "")
	if _, err = admin.Exec(ctx, "CREATE DATABASE "+pgx.Identifier{name}.Sanitize()); err != nil {
		return errors.New("cannot create isolated restore database")
	}
	defer func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if _, err := admin.Exec(cleanupCtx, "DROP DATABASE "+pgx.Identifier{name}.Sanitize()+" WITH (FORCE)"); err != nil {
			result = fmt.Errorf("isolated restore database cleanup failed: %s", name)
		}
	}()
	env, err := pgtools.Environment(c.DatabaseURL, name)
	if err != nil {
		return err
	}
	cmd := pgtools.Command(ctx, *bin, "pg_restore", env, "--exit-on-error", "--no-owner", "--no-privileges", "--dbname", name, *input)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	if err = cmd.Run(); err != nil {
		return errors.New("isolated pg_restore failed")
	}
	uri, _ := url.Parse(c.DatabaseURL)
	uri.Path = "/" + name
	c.DatabaseURL = uri.String()
	pool, err := database.Open(ctx, c)
	if err != nil {
		return errors.New("restored database unavailable")
	}
	defer pool.Close()
	if _, err = database.Migrate(ctx, pool); err != nil {
		return errors.New("restored schema migration failed")
	}
	if err = database.CheckSchema(ctx, pool); err != nil {
		return errors.New("restored schema invalid")
	}
	var transactions, bills, payments int64
	if err = pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM transactions),(SELECT count(*) FROM bills),(SELECT count(*) FROM bill_payments)`).Scan(&transactions, &bills, &payments); err != nil {
		return errors.New("restored finance check failed")
	}
	// Rehearse the post-restore security reset only inside the isolated clone.
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	for _, table := range []string{"sessions", "account_tokens", "mail_outbox"} {
		if _, err = tx.Exec(ctx, "DELETE FROM "+table); err != nil {
			return errors.New("restore security reset failed")
		}
	}
	if _, err = tx.Exec(ctx, `UPDATE sync_dataset SET dataset_id=$1,changed_at=clock_timestamp() WHERE id=1`, service.NewID()); err != nil {
		return errors.New("restore dataset rotation failed")
	}
	if err = tx.Commit(ctx); err != nil {
		return errors.New("restore reset commit failed")
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{"status": "restored_and_checked_in_isolated_database", "transactions": transactions, "bills": bills, "payments": payments, "security_reset_rehearsed": true})
}
