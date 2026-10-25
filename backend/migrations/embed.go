package migrations

import "embed"

// Files contains immutable, forward-only database migrations.
//
//go:embed *.sql
var Files embed.FS
