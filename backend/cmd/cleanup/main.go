package main

import (
	"catatuang/backend/internal/config"
	"catatuang/backend/internal/database"
	"catatuang/backend/internal/service"
	"context"
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
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := database.Open(ctx, c)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err = database.CheckSchema(ctx, pool); err != nil {
		return err
	}
	if err = service.New(pool).Cleanup(ctx); err != nil {
		return fmt.Errorf("session cleanup failed")
	}
	fmt.Println("expired sessions and auth rate limits removed")
	return nil
}
