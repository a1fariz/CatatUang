package main

import (
	"catatuang/backend/internal/config"
	"catatuang/backend/internal/database"
	"catatuang/backend/internal/service"
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
	flags := flag.NewFlagSet("cleanup", flag.ContinueOnError)
	dryRun := flags.Bool("dry-run", false, "Report expired records using a read-only snapshot; do not delete")
	jsonOutput := flags.Bool("json", false, "Write aggregate counts as JSON")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("unexpected positional arguments")
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
	if err = database.CheckSchema(ctx, pool); err != nil {
		return err
	}
	report, err := service.New(pool).CleanupReport(ctx, *dryRun)
	if err != nil {
		return errors.New("expired authentication record cleanup failed")
	}
	if *jsonOutput {
		return json.NewEncoder(output).Encode(report)
	}
	verb := "removed"
	if *dryRun {
		verb = "eligible (dry run; no records removed)"
	}
	_, err = fmt.Fprintf(output, "expired records %s: sessions=%d auth_rate_limits=%d account_tokens=%d mail_outbox=%d\n", verb, report.Sessions, report.AuthRateLimits, report.AccountTokens, report.MailOutbox)
	return err
}
