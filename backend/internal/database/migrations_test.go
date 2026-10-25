package database

import "testing"

func TestVerifyMigrationHistory(t *testing.T) {
	files := []Migration{{Name: "001.sql", Checksum: "one"}, {Name: "002.sql", Checksum: "two"}}
	for _, tt := range []struct {
		name    string
		applied map[string]string
		fail    bool
	}{
		{"empty", map[string]string{}, false},
		{"partial", map[string]string{"001.sql": "one"}, false},
		{"current", map[string]string{"001.sql": "one", "002.sql": "two"}, false},
		{"changed", map[string]string{"001.sql": "changed"}, true},
		{"unknown", map[string]string{"003.sql": "three"}, true},
		{"gap", map[string]string{"002.sql": "two"}, true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if err := verifyHistory(files, tt.applied); (err != nil) != tt.fail {
				t.Fatalf("unexpected result %v", err)
			}
		})
	}
}

func TestBundledMigrations(t *testing.T) {
	files, err := BundledMigrations()
	if err != nil {
		t.Fatal(err)
	}
	if len(files) == 0 {
		t.Fatal("no migration bundled")
	}
	for _, file := range files {
		if len(file.Checksum) != 64 || file.SQL == "" {
			t.Fatal("invalid migration")
		}
	}
}
