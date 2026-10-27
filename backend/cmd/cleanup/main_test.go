package main

import (
	"bytes"
	"errors"
	"flag"
	"strings"
	"testing"
)

func TestCleanupArgumentsBeforeDatabaseAccess(t *testing.T) {
	t.Setenv("DATABASE_URL", "")
	for _, args := range [][]string{{"unexpected"}, {"-dry-run=invalid"}, {"-unknown"}} {
		var out bytes.Buffer
		err := run(args, &out)
		if err == nil || strings.Contains(err.Error(), "DATABASE_URL") || out.Len() != 0 {
			t.Fatal("invalid cleanup arguments not rejected")
		}
	}
	if err := run([]string{"-help"}, &bytes.Buffer{}); !errors.Is(err, flag.ErrHelp) {
		t.Fatal("help unexpectedly accessed database")
	}
}
