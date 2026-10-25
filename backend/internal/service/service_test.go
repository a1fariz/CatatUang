package service

import (
	"strings"
	"testing"
	"time"
)

func TestPasswordHash(t *testing.T) {
	password := "rahasia-untuk-pengujian-2026"
	first, second := HashPassword(password), HashPassword(password)
	if first == second || strings.Contains(first, password) {
		t.Fatal("password hashing is not salted")
	}
	if !CheckPassword(first, password) || CheckPassword(first, "password-yang-salah") {
		t.Fatal("password verification failed")
	}
	for _, invalid := range []string{"", hashPrefix + "bad$bad", strings.Replace(first, "m=65536", "m=999999999", 1)} {
		if CheckPassword(invalid, password) {
			t.Fatal("malformed hash accepted")
		}
	}
}
func TestInputValidation(t *testing.T) {
	for _, email := range []string{"bad", "Name <a@example.com>", "a@example.com\r\nattack", "é@example.com"} {
		if _, err := NormalizeEmail(email); err == nil {
			t.Fatalf("accepted email %q", email)
		}
	}
	if email, err := NormalizeEmail(" Person@Example.com "); err != nil || email != "person@example.com" {
		t.Fatal(email, err)
	}
	if validPassword("short") || validPassword(strings.Repeat("a", 129)) || !validPassword("password-untuk-testing") {
		t.Fatal("password length constraints failed")
	}
	id := NewID()
	if !ValidID(id) || ValidID("00000000-0000-0000-0000-000000000000") || ValidID("11111111-1111-1111-1111-1111111111--") {
		t.Fatal("UUID validation failed")
	}
	in := TransactionInput{Type: "expense", AmountMinor: 100, CurrencyCode: "IDR", Category: "Makan", OccurredOn: "2026-10-25"}
	if err := in.Validate(); err != nil {
		t.Fatal(err)
	}
	in.Category = "Gaji"
	if in.Validate() == nil {
		t.Fatal("mismatched category accepted")
	}
	in.Category = "Makan"
	in.AmountMinor = MaxAmount + 1
	if in.Validate() == nil {
		t.Fatal("unsafe JSON amount accepted")
	}
	if ValidDate("2026-02-29") || ValidDate("2026-1-1") {
		t.Fatal("bad date accepted")
	}
}
func TestCalendarRecurrence(t *testing.T) {
	tests := []struct {
		name, due, zone, recurrence, want string
		anchor                            int
	}{
		{"short month", "2025-01-31T09:00:00+07:00", "Asia/Jakarta", "monthly", "2025-02-28T02:00:00Z", 31},
		{"restore anchor", "2025-02-28T09:00:00+07:00", "Asia/Jakarta", "monthly", "2025-03-31T02:00:00Z", 31},
		{"leap year", "2027-02-28T09:00:00Z", "UTC", "yearly", "2028-02-29T09:00:00Z", 29},
		{"weekly daylight saving", "2026-03-01T09:00:00-05:00", "America/New_York", "weekly", "2026-03-08T13:00:00Z", 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			due, _ := time.Parse(time.RFC3339, tt.due)
			input := BillInput{Name: "Tagihan", AmountMinor: 100, CurrencyCode: "IDR", DueAt: due, Timezone: tt.zone, Recurrence: tt.recurrence, RecurrenceDay: tt.anchor}
			if err := input.Validate(); err != nil {
				t.Fatal(err)
			}
			next, err := NextDue(input)
			if err != nil || next.Format(time.RFC3339) != tt.want {
				t.Fatalf("next=%v err=%v want=%s", next, err, tt.want)
			}
		})
	}
}
