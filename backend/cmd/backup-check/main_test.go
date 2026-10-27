package main

import (
	"bytes"
	"catatuang/backend/internal/pgtools"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestBackupCheck(t *testing.T) {
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		name      string
		age       time.Duration
		mutation  string
		wantAlert string
		invalid   bool
	}{
		{"fresh", time.Hour, "", "", false},
		{"boundary", 24 * time.Hour, "", "", false},
		{"stale", 25 * time.Hour, "", "backup_age_limit_exceeded", false},
		{"future", -time.Second, "", "backup_timestamp_in_future", false},
		{"tampered", time.Hour, "dump", "", true},
		{"trailing-json", time.Hour, "trailing", "", true},
		{"oversize", time.Hour, "oversize", "", true},
		{"missing-manifest", time.Hour, "missing", "", true},
		{"zero-time", time.Hour, "zero-time", "", true},
		{"empty", time.Hour, "empty", "", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			file := filepath.Join(t.TempDir(), "fixture.dump")
			if err := os.WriteFile(file, []byte("PGDMP fixture, not a restorable database"), 0600); err != nil {
				t.Fatal(err)
			}
			hash, err := pgtools.Checksum(file)
			if err != nil {
				t.Fatal(err)
			}
			m := pgtools.Manifest{Version: 1, Format: "pg_dump-custom", SHA256: hash, CreatedAt: now.Add(-tc.age)}
			if tc.mutation == "zero-time" {
				m.CreatedAt = time.Time{}
			}
			data, err := json.Marshal(m)
			if err != nil {
				t.Fatal(err)
			}
			switch tc.mutation {
			case "trailing":
				data = append(data, []byte(" {}")...)
			case "oversize":
				data = append(data, []byte(strings.Repeat(" ", 4096))...)
			case "dump":
				if err = os.WriteFile(file, []byte("damaged"), 0600); err != nil {
					t.Fatal(err)
				}
			case "empty":
				if err = os.WriteFile(file, nil, 0600); err != nil {
					t.Fatal(err)
				}
			}
			if tc.mutation != "missing" {
				if err = os.WriteFile(file+".json", data, 0600); err != nil {
					t.Fatal(err)
				}
			}
			var out bytes.Buffer
			err = run([]string{"-in", file}, &out, now)
			if tc.invalid {
				if err == nil || out.Len() != 0 {
					t.Fatal("invalid backup produced success snapshot")
				}
				return
			}
			var report struct {
				Status        string   `json:"status"`
				ChecksumValid bool     `json:"checksum_valid"`
				Alerts        []string `json:"alerts"`
			}
			if json.Unmarshal(out.Bytes(), &report) != nil || !report.ChecksumValid {
				t.Fatal("valid checksum report missing")
			}
			if tc.wantAlert == "" {
				if err != nil || report.Status != "ok" || len(report.Alerts) != 0 {
					t.Fatal("fresh backup rejected")
				}
			} else if err == nil || report.Status != "alert" || len(report.Alerts) != 1 || report.Alerts[0] != tc.wantAlert {
				t.Fatal("backup age alert missing")
			}
		})
	}
}

func TestInvalidBackupCheckOptions(t *testing.T) {
	for _, args := range [][]string{nil, {"-in", "unused", "-max-age", "0s"}, {"-in", "unused", "-max-age", "-1s"}, {"-in", "unused", "extra"}} {
		if run(args, &bytes.Buffer{}, time.Now()) == nil {
			t.Fatal("invalid arguments accepted")
		}
	}
}
