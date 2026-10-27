package main

import (
	"catatuang/backend/internal/pgtools"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"time"
)

func main() {
	if err := run(os.Args[1:], os.Stdout, time.Now()); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return
		}
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string, output io.Writer, now time.Time) error {
	flags := flag.NewFlagSet("backup-check", flag.ContinueOnError)
	input := flags.String("in", "", "Backup dump path with checksum manifest")
	maxAge := flags.Duration("max-age", 24*time.Hour, "Maximum age since manifest creation; must be positive")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *input == "" || flags.NArg() != 0 || *maxAge <= 0 {
		return errors.New("usage: backup-check -in backup.dump [-max-age 24h]; max-age must be positive")
	}
	info, err := os.Stat(*input)
	if err != nil || !info.Mode().IsRegular() || info.Size() == 0 {
		return errors.New("backup must be an accessible nonempty regular file")
	}
	manifest, err := pgtools.VerifiedManifest(*input)
	if err != nil {
		return err
	}
	age := now.Sub(manifest.CreatedAt)
	alerts := []string{}
	if age < 0 {
		alerts = append(alerts, "backup_timestamp_in_future")
	}
	if age > *maxAge {
		alerts = append(alerts, "backup_age_limit_exceeded")
	}
	status := "ok"
	if len(alerts) > 0 {
		status = "alert"
	}
	if err = json.NewEncoder(output).Encode(struct {
		Status        string    `json:"status"`
		ChecksumValid bool      `json:"checksum_valid"`
		CreatedAt     time.Time `json:"created_at"`
		AgeSeconds    float64   `json:"age_seconds"`
		SizeBytes     int64     `json:"size_bytes"`
		Alerts        []string  `json:"alerts"`
	}{status, true, manifest.CreatedAt, age.Seconds(), info.Size(), alerts}); err != nil {
		return errors.New("backup status output failed")
	}
	if len(alerts) > 0 {
		return errors.New("backup thresholds exceeded; see JSON alerts")
	}
	return nil
}
