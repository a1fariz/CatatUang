package main

import (
	"catatuang/backend/internal/config"
	"catatuang/backend/internal/pgtools"
	"context"
	"encoding/json"
	"errors"
	"flag"
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
	output := flag.String("out", "", "New custom-format dump path; never overwrites")
	bin := flag.String("pg-bin", "", "PostgreSQL 18 bin directory; empty uses PATH")
	flag.Parse()
	if *output == "" || flag.NArg() != 0 {
		return errors.New("usage: backup -out new-file.dump [-pg-bin directory]")
	}
	c, err := config.Load()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	manifest, err := pgtools.Backup(ctx, c.DatabaseURL, *bin, *output)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(manifest)
}
