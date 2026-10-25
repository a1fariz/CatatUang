package main

import (
	"catatuang/backend/internal/config"
	"catatuang/backend/internal/database"
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
	if len(os.Args) != 2 || (os.Args[1] != "up" && os.Args[1] != "status") {
		return fmt.Errorf("usage: migrate up|status")
	}
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
	if os.Args[1] == "status" {
		if err := database.CheckSchema(ctx, pool); err != nil {
			return err
		}
		fmt.Println("schema is current")
		return nil
	}
	n, err := database.Migrate(ctx, pool)
	if err != nil {
		return err
	}
	fmt.Printf("applied %d migration(s)\n", n)
	return nil
}
