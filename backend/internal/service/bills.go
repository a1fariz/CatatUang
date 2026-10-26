package service

import (
	"context"
	"time"
	_ "time/tzdata"

	"github.com/jackc/pgx/v5"
)

type BillInput struct {
	Name            string    `json:"name"`
	AmountMinor     int64     `json:"amount_minor"`
	CurrencyCode    string    `json:"currency_code"`
	DueAt           time.Time `json:"due_at"`
	Timezone        string    `json:"timezone"`
	Recurrence      string    `json:"recurrence"`
	RecurrenceDay   int       `json:"recurrence_day"`
	ReminderMinutes *int      `json:"reminder_minutes"`
}
type Bill struct {
	ID string `json:"id"`
	BillInput
	Status    string     `json:"status"`
	PaidAt    *time.Time `json:"paid_at"`
	Version   int64      `json:"version"`
	CreatedAt time.Time  `json:"created_at"`
	UpdatedAt time.Time  `json:"updated_at"`
}
type Payment struct {
	ID           string    `json:"id"`
	BillID       string    `json:"bill_id"`
	DueAt        time.Time `json:"due_at"`
	AmountMinor  int64     `json:"amount_minor"`
	CurrencyCode string    `json:"currency_code"`
	PaidAt       time.Time `json:"paid_at"`
}
type PaymentResult struct {
	Payment  Payment `json:"payment"`
	Bill     Bill    `json:"bill"`
	Replayed bool    `json:"replayed"`
}

func (in BillInput) Validate() error {
	if !validText(in.Name, 80) || !validAmount(in.AmountMinor) || !validCurrency(in.CurrencyCode) || in.DueAt.IsZero() || in.DueAt.Year() < 2000 || in.DueAt.Year() > 2100 || in.DueAt.Nanosecond() != 0 || in.RecurrenceDay < 1 || in.RecurrenceDay > 31 {
		return ErrInvalid
	}
	if in.Recurrence != "once" && in.Recurrence != "weekly" && in.Recurrence != "monthly" && in.Recurrence != "yearly" {
		return ErrInvalid
	}
	if in.ReminderMinutes != nil && (*in.ReminderMinutes < 0 || *in.ReminderMinutes > 525600) {
		return ErrInvalid
	}
	if !validText(in.Timezone, 100) || in.Timezone == "Local" {
		return ErrInvalid
	}
	zone, err := time.LoadLocation(in.Timezone)
	if err != nil {
		return ErrInvalid
	}
	local := in.DueAt.In(zone)
	if (in.Recurrence == "monthly" || in.Recurrence == "yearly") && local.Day() != min(in.RecurrenceDay, time.Date(local.Year(), local.Month()+1, 0, 0, 0, 0, 0, zone).Day()) {
		return ErrInvalid
	}
	return nil
}

// Recurrence preserves wall-clock time and the original day in the bill's zone.
func NextDue(in BillInput) (time.Time, error) {
	zone, err := time.LoadLocation(in.Timezone)
	if err != nil {
		return time.Time{}, ErrInvalid
	}
	local := in.DueAt.In(zone)
	year, month, day := local.Date()
	switch in.Recurrence {
	case "weekly":
		day += 7
	case "monthly":
		month++
		day = in.RecurrenceDay
	case "yearly":
		year++
		day = in.RecurrenceDay
	default:
		return time.Time{}, ErrInvalid
	}
	if in.Recurrence != "weekly" {
		day = min(day, time.Date(year, month+1, 0, 0, 0, 0, 0, zone).Day())
	}
	next := time.Date(year, month, day, local.Hour(), local.Minute(), local.Second(), 0, zone)
	if !next.After(in.DueAt) || next.Year() > 2100 {
		return time.Time{}, ErrInvalid
	}
	return next.UTC(), nil
}

const billColumns = `id::text,name,amount_minor,currency_code,due_at,timezone,recurrence,recurrence_day,reminder_minutes,status,paid_at,version,created_at,updated_at`

func scanBill(row pgx.Row) (Bill, error) {
	var b Bill
	err := row.Scan(&b.ID, &b.Name, &b.AmountMinor, &b.CurrencyCode, &b.DueAt, &b.Timezone, &b.Recurrence, &b.RecurrenceDay, &b.ReminderMinutes, &b.Status, &b.PaidAt, &b.Version, &b.CreatedAt, &b.UpdatedAt)
	return b, dbError(err)
}
func (s *Service) GetBill(ctx context.Context, user, id string) (Bill, error) {
	return scanBill(s.Pool.QueryRow(ctx, "SELECT "+billColumns+" FROM bills WHERE user_id=$1 AND id=$2 AND deleted_at IS NULL", user, id))
}
func (s *Service) ListBills(ctx context.Context, user string, o ListOptions) ([]Bill, error) {
	rows, err := s.Pool.Query(ctx, "SELECT "+billColumns+" FROM bills WHERE user_id=$1 AND deleted_at IS NULL ORDER BY due_at,id LIMIT $2 OFFSET $3", user, o.Limit+1, o.Offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []Bill{}
	for rows.Next() {
		b, err := scanBill(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, b)
	}
	return result, rows.Err()
}
func (s *Service) SaveBill(ctx context.Context, user, id string, version int64, in BillInput) (Bill, error) {
	if err := in.Validate(); err != nil {
		return Bill{}, err
	}
	if id == "" {
		id = NewID()
		return scanBill(s.Pool.QueryRow(ctx, `INSERT INTO bills(id,user_id,name,amount_minor,currency_code,due_at,timezone,recurrence,recurrence_day,reminder_minutes)
  VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING `+billColumns, id, user, in.Name, in.AmountMinor, in.CurrencyCode, in.DueAt, in.Timezone, in.Recurrence, in.RecurrenceDay, in.ReminderMinutes))
	}
	b, err := scanBill(s.Pool.QueryRow(ctx, `UPDATE bills SET name=$3,amount_minor=$4,currency_code=$5,due_at=$6,timezone=$7,recurrence=$8,recurrence_day=$9,reminder_minutes=$10
  WHERE user_id=$1 AND id=$2 AND version=$11 AND deleted_at IS NULL AND status='active' RETURNING `+billColumns, user, id, in.Name, in.AmountMinor, in.CurrencyCode, in.DueAt, in.Timezone, in.Recurrence, in.RecurrenceDay, in.ReminderMinutes, version))
	if err == ErrNotFound {
		return b, s.mutationError(ctx, "bills", user, id)
	}
	return b, err
}
func (s *Service) PayBill(ctx context.Context, user, id, key string, version int64, due time.Time) (PaymentResult, error) {
	if !ValidID(key) || due.IsZero() || due.Nanosecond() != 0 {
		return PaymentResult{}, ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return PaymentResult{}, err
	}
	defer tx.Rollback(context.Background())
	b, err := scanBill(tx.QueryRow(ctx, "SELECT "+billColumns+" FROM bills WHERE user_id=$1 AND id=$2 AND deleted_at IS NULL FOR UPDATE", user, id))
	if err != nil {
		return PaymentResult{}, err
	}
	existing, err := scanPayment(tx.QueryRow(ctx, "SELECT "+paymentColumns+" FROM bill_payments WHERE user_id=$1 AND id=$2", user, key))
	if err == nil {
		if existing.BillID != id || !existing.DueAt.Equal(due) {
			return PaymentResult{}, ErrConflict
		}
		return PaymentResult{existing, b, true}, nil
	}
	if err != ErrNotFound {
		return PaymentResult{}, err
	}
	if b.Version != version || b.Status != "active" || !b.DueAt.Equal(due) {
		return PaymentResult{}, ErrConflict
	}
	var historyCount int
	if err = tx.QueryRow(ctx, `SELECT count(*) FROM bill_payments WHERE user_id=$1 AND bill_id=$2`, user, id).Scan(&historyCount); err != nil {
		return PaymentResult{}, err
	}
	if historyCount >= 2000 {
		return PaymentResult{}, ErrInvalid
	}
	payment, err := scanPayment(tx.QueryRow(ctx, `INSERT INTO bill_payments(id,user_id,bill_id,due_at,amount_minor,currency_code,paid_at) VALUES($1,$2,$3,$4,$5,$6,now()) RETURNING `+paymentColumns, key, user, id, b.DueAt, b.AmountMinor, b.CurrencyCode))
	if err != nil {
		return PaymentResult{}, err
	}
	if b.Recurrence == "once" {
		b, err = scanBill(tx.QueryRow(ctx, "UPDATE bills SET status='paid',paid_at=$3 WHERE user_id=$1 AND id=$2 RETURNING "+billColumns, user, id, payment.PaidAt))
	} else {
		next, e := NextDue(b.BillInput)
		if e != nil {
			return PaymentResult{}, e
		}
		b, err = scanBill(tx.QueryRow(ctx, "UPDATE bills SET due_at=$3 WHERE user_id=$1 AND id=$2 RETURNING "+billColumns, user, id, next))
	}
	if err != nil {
		return PaymentResult{}, err
	}
	if err = tx.Commit(ctx); err != nil {
		return PaymentResult{}, dbError(err)
	}
	return PaymentResult{payment, b, false}, nil
}

const paymentColumns = `id::text,bill_id::text,due_at,amount_minor,currency_code,paid_at`

func scanPayment(row pgx.Row) (Payment, error) {
	var p Payment
	err := row.Scan(&p.ID, &p.BillID, &p.DueAt, &p.AmountMinor, &p.CurrencyCode, &p.PaidAt)
	return p, dbError(err)
}
func (s *Service) ListPayments(ctx context.Context, user, id string, o ListOptions) ([]Payment, error) {
	if _, err := s.GetBill(ctx, user, id); err != nil {
		return nil, err
	}
	rows, err := s.Pool.Query(ctx, "SELECT "+paymentColumns+" FROM bill_payments WHERE user_id=$1 AND bill_id=$2 ORDER BY paid_at DESC,id DESC LIMIT $3 OFFSET $4", user, id, o.Limit+1, o.Offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []Payment{}
	for rows.Next() {
		p, err := scanPayment(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, p)
	}
	return result, rows.Err()
}
