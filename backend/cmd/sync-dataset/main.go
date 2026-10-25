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
	if len(os.Args) != 2 || (os.Args[1] != "status" && os.Args[1] != "rotate-after-restore") {
		return fmt.Errorf("usage: sync-dataset status|rotate-after-restore")
	}
	c, err := config.Load()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := database.Open(ctx, c)
	if err != nil {
		return fmt.Errorf("database unavailable")
	}
	defer pool.Close()
	if err = database.CheckSchema(ctx, pool); err != nil {
		return err
	}
	if os.Args[1] == "rotate-after-restore" {
		tag, err := pool.Exec(ctx, `UPDATE sync_dataset SET dataset_id=$1,changed_at=clock_timestamp() WHERE id=1`, service.NewID())
		if err != nil || tag.RowsAffected() != 1 {
			return fmt.Errorf("dataset rotation failed")
		}
	}
	id, err := service.New(pool).SyncDataset(ctx)
	if err != nil {
		return fmt.Errorf("dataset identity unavailable")
	}
	fmt.Println(id)
	return nil
}
