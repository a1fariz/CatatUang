package main

import (
	"catatuang/backend/internal/config"
	"catatuang/backend/internal/database"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run() error {
	c, err := config.Load()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.DBTimeout+time.Second)
	defer cancel()
	pool, err := database.Open(ctx, c)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err = database.CheckSchema(ctx, pool); err != nil {
		return errors.New("schema not ready")
	}
	var pending, failed, expired int64
	var oldest float64
	err = pool.QueryRow(ctx, `SELECT count(*) FILTER(WHERE expires_at>clock_timestamp() AND attempts<8),count(*) FILTER(WHERE expires_at>clock_timestamp() AND attempts>=8),COALESCE(EXTRACT(EPOCH FROM clock_timestamp()-min(available_at) FILTER(WHERE expires_at>clock_timestamp() AND attempts<8)),0),(SELECT count(*) FROM sessions WHERE expires_at<=clock_timestamp()) FROM mail_outbox`).Scan(&pending, &failed, &oldest, &expired)
	if err != nil {
		return errors.New("operational query failed")
	}
	if oldest < 0 {
		oldest = 0
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{"schema": "ready", "mail_pending": pending, "mail_failed": failed, "mail_oldest_available_age_seconds": oldest, "expired_sessions": expired, "pool_acquired": pool.Stat().AcquiredConns(), "pool_total": pool.Stat().TotalConns()})
}
