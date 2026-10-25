package database

import (
	"context"
	"fmt"
	"time"

	"catatuang/backend/internal/config"
	"github.com/jackc/pgx/v5/pgxpool"
)

func Open(ctx context.Context, c config.Config) (*pgxpool.Pool, error) {
	pc, err := pgxpool.ParseConfig(c.DatabaseURL)
	if err != nil {
		return nil, fmt.Errorf("invalid database configuration")
	}
	pc.MaxConns = c.MaxConnections
	pc.ConnConfig.ConnectTimeout = c.DBTimeout
	pc.ConnConfig.RuntimeParams["application_name"] = "catatuang"
	pc.ConnConfig.RuntimeParams["timezone"] = "UTC"
	pc.ConnConfig.RuntimeParams["search_path"] = "public"
	pc.ConnConfig.RuntimeParams["statement_timeout"] = fmt.Sprint(c.DBTimeout.Milliseconds())
	pc.MaxConnLifetime = 30 * time.Minute
	pc.MaxConnIdleTime = 5 * time.Minute
	pool, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		return nil, fmt.Errorf("cannot create database pool")
	}
	pingCtx, cancel := context.WithTimeout(ctx, c.DBTimeout)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("database unavailable; check connectivity and credentials")
	}
	return pool, nil
}
