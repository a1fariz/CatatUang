package service

import (
	"context"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
)

const MaxAmount int64 = 9007199254740991 // Maximum exact JSON integer on all Flutter targets.
type TransactionInput struct {
	Type         string `json:"type"`
	AmountMinor  int64  `json:"amount_minor"`
	CurrencyCode string `json:"currency_code"`
	Category     string `json:"category"`
	OccurredOn   string `json:"occurred_on"`
	Note         string `json:"note"`
}
type Transaction struct {
	ID string `json:"id"`
	TransactionInput
	Version   int64     `json:"version"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}
type ListOptions struct {
	Limit, Offset  int
	From, To, Type string
}

func validText(text string, max int) bool {
	return utf8.ValidString(text) && utf8.RuneCountInString(strings.TrimSpace(text)) > 0 && utf8.RuneCountInString(text) <= max && !strings.ContainsRune(text, 0)
}
func validCurrency(code string) bool {
	return code == "IDR" || code == "USD" || code == "EUR" || code == "SGD"
}
func validAmount(amount int64) bool { return amount > 0 && amount <= MaxAmount }
func ValidDate(date string) bool {
	_, err := time.Parse("2006-01-02", date)
	return err == nil && len(date) == 10 && date >= "2000-01-01" && date < "2101-01-01"
}
func (in TransactionInput) Validate() error {
	if !validAmount(in.AmountMinor) || !validCurrency(in.CurrencyCode) || !ValidDate(in.OccurredOn) || !utf8.ValidString(in.Note) || utf8.RuneCountInString(in.Note) > 200 || strings.ContainsRune(in.Note, 0) {
		return ErrInvalid
	}
	categories := map[string][]string{"income": {"Gaji", "Bonus", "Lainnya"}, "expense": {"Makan", "Transportasi", "Belanja", "Tagihan", "Lainnya"}}
	for _, category := range categories[in.Type] {
		if in.Category == category {
			return nil
		}
	}
	return ErrInvalid
}

const transactionColumns = `id::text,type,amount_minor,currency_code,category,occurred_on::text,note,version,created_at,updated_at`

func scanTransaction(row pgx.Row) (Transaction, error) {
	var v Transaction
	err := row.Scan(&v.ID, &v.Type, &v.AmountMinor, &v.CurrencyCode, &v.Category, &v.OccurredOn, &v.Note, &v.Version, &v.CreatedAt, &v.UpdatedAt)
	return v, dbError(err)
}
func (s *Service) ListTransactions(ctx context.Context, user string, o ListOptions) ([]Transaction, error) {
	rows, err := s.Pool.Query(ctx, `SELECT `+transactionColumns+` FROM transactions WHERE user_id=$1 AND deleted_at IS NULL
  AND ($2::text='' OR occurred_on >= NULLIF($2,'')::date) AND ($3::text='' OR occurred_on < NULLIF($3,'')::date)
  AND ($4::text='' OR type=$4) ORDER BY occurred_on DESC,id DESC LIMIT $5 OFFSET $6`, user, o.From, o.To, o.Type, o.Limit+1, o.Offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []Transaction{}
	for rows.Next() {
		v, err := scanTransaction(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, v)
	}
	return result, rows.Err()
}
func (s *Service) GetTransaction(ctx context.Context, user, id string) (Transaction, error) {
	return scanTransaction(s.Pool.QueryRow(ctx, "SELECT "+transactionColumns+" FROM transactions WHERE user_id=$1 AND id=$2 AND deleted_at IS NULL", user, id))
}
func (s *Service) SaveTransaction(ctx context.Context, user, id string, version int64, in TransactionInput) (Transaction, error) {
	if err := in.Validate(); err != nil {
		return Transaction{}, err
	}
	if id == "" {
		id = NewID()
		return scanTransaction(s.Pool.QueryRow(ctx, `INSERT INTO transactions(id,user_id,type,amount_minor,currency_code,category,occurred_on,note)
   VALUES($1,$2,$3,$4,$5,$6,$7,$8) RETURNING `+transactionColumns, id, user, in.Type, in.AmountMinor, in.CurrencyCode, in.Category, in.OccurredOn, in.Note))
	}
	v, err := scanTransaction(s.Pool.QueryRow(ctx, `UPDATE transactions SET type=$3,amount_minor=$4,currency_code=$5,category=$6,occurred_on=$7,note=$8
  WHERE user_id=$1 AND id=$2 AND version=$9 AND deleted_at IS NULL RETURNING `+transactionColumns, user, id, in.Type, in.AmountMinor, in.CurrencyCode, in.Category, in.OccurredOn, in.Note, version))
	if err == ErrNotFound {
		return v, s.mutationError(ctx, "transactions", user, id)
	}
	return v, err
}
func (s *Service) mutationError(ctx context.Context, table, user, id string) error {
	// Table is selected by server code, never by an HTTP parameter.
	if table != "transactions" && table != "bills" {
		return ErrInvalid
	}
	var exists bool
	err := s.Pool.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM "+table+" WHERE user_id=$1 AND id=$2 AND deleted_at IS NULL)", user, id).Scan(&exists)
	if err != nil {
		return err
	}
	if exists {
		return ErrConflict
	}
	return ErrNotFound
}
func (s *Service) Delete(ctx context.Context, table, user, id string, version int64) error {
	if table != "transactions" && table != "bills" {
		return ErrInvalid
	}
	tag, err := s.Pool.Exec(ctx, "UPDATE "+table+" SET deleted_at=now() WHERE user_id=$1 AND id=$2 AND version=$3 AND deleted_at IS NULL", user, id, version)
	if err != nil {
		return dbError(err)
	}
	if tag.RowsAffected() == 0 {
		return s.mutationError(ctx, table, user, id)
	}
	return nil
}
