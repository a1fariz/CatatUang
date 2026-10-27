package main

import (
	"bytes"
	"errors"
	"flag"
	"strings"
	"testing"
)

func TestRejectInvalidMonitoringOptionsBeforeDatabaseAccess(t *testing.T) {
	t.Setenv("DATABASE_URL", "")
	for _, args := range [][]string{{"-max-mail-failed=-2"}, {"-max-mail-age=-1s"}, {"-max-mail-age=invalid"}, {"unexpected"}} {
		var out bytes.Buffer
		err := run(args, &out)
		if err == nil || strings.Contains(err.Error(), "DATABASE_URL") || out.Len() != 0 {
			t.Fatalf("invalid monitoring arguments not rejected: %v", args)
		}
	}
	if err := run([]string{"-help"}, &bytes.Buffer{}); !errors.Is(err, flag.ErrHelp) {
		t.Fatal("help unexpectedly required database")
	}
}
