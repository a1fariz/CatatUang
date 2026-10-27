package main

import (
	"catatuang/backend/internal/config"
	"catatuang/backend/internal/database"
	"catatuang/backend/internal/opsstatus"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"time"
)

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return
		}
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run(args []string, output io.Writer) error {
	flags := flag.NewFlagSet("ops-status", flag.ContinueOnError)
	limits := opsstatus.Limits{}
	flags.Int64Var(&limits.MaxMailFailed, "max-mail-failed", -1, "maximum failed mail jobs; -1 disables the threshold")
	flags.DurationVar(&limits.MaxMailAge, "max-mail-age", 0, "maximum pending mail age since available_at; 0 disables the threshold")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	if err := limits.Validate(); err != nil {
		return err
	}
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
	snapshot, err := opsstatus.Collect(ctx, pool)
	if err != nil {
		return errors.New("operational query failed")
	}
	snapshot.Alerts = snapshot.Evaluate(limits)
	if err = json.NewEncoder(output).Encode(snapshot); err != nil {
		return errors.New("operational output failed")
	}
	if len(snapshot.Alerts) > 0 {
		return errors.New("operational thresholds exceeded; see JSON alerts")
	}
	return nil
}
