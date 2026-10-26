package service

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

type BillSyncRecord struct {
	Bill
	Deleted  bool      `json:"deleted"`
	Payments []Payment `json:"payments"`
}
type BillSyncPayload struct {
	BillInput
	Status   string     `json:"status"`
	PaidAt   *time.Time `json:"paid_at"`
	Payments []Payment  `json:"payments"`
}
type BillSyncMutation struct {
	OperationID string           `json:"operation_id"`
	ID          string           `json:"id"`
	BaseVersion int64            `json:"base_version"`
	Deleted     bool             `json:"deleted"`
	Payload     *BillSyncPayload `json:"payload"`
}
type BillSyncChange struct {
	Sequence int64          `json:"sequence"`
	Record   BillSyncRecord `json:"record"`
}
type BillSyncPage struct {
	Items   []BillSyncChange `json:"items"`
	Cursor  int64            `json:"cursor"`
	HasMore bool             `json:"has_more"`
}

func (in BillSyncMutation) Validate() error {
	if !ValidID(in.OperationID) || !ValidID(in.ID) || in.BaseVersion < 0 || in.BaseVersion >= MaxAmount {
		return ErrInvalid
	}
	if in.Deleted {
		if in.Payload != nil || in.BaseVersion == 0 {
			return ErrInvalid
		}
		return nil
	}
	p := in.Payload
	if p == nil || p.BillInput.Validate() != nil || len(p.Payments) > 2000 {
		return ErrInvalid
	}
	if p.Status != "active" && p.Status != "paid" && p.Status != "cancelled" {
		return ErrInvalid
	}
	if (p.Status == "paid") != (p.PaidAt != nil) || p.Status == "paid" && p.Recurrence != "once" {
		return ErrInvalid
	}
	ids, dues := map[string]bool{}, map[int64]bool{}
	paidMatch := false
	for _, payment := range p.Payments {
		due := payment.DueAt.Unix()
		if !ValidID(payment.ID) || payment.BillID != in.ID || !validAmount(payment.AmountMinor) || payment.CurrencyCode != p.CurrencyCode || !validBillTime(payment.DueAt) || !validPaymentTime(payment.PaidAt) || ids[payment.ID] || dues[due] {
			return ErrInvalid
		}
		ids[payment.ID], dues[due] = true, true
		if p.PaidAt != nil && payment.DueAt.Equal(p.DueAt) && payment.PaidAt.Equal(*p.PaidAt) {
			paidMatch = true
		}
		if p.Status == "active" && !payment.DueAt.Before(p.DueAt) {
			return ErrInvalid
		}
	}
	if p.Status == "paid" && (!validPaymentTime(*p.PaidAt) || !paidMatch) {
		return ErrInvalid
	}
	return nil
}
func validBillTime(t time.Time) bool {
	return !t.IsZero() && t.Year() >= 2000 && t.Year() <= 2100 && t.Nanosecond() == 0
}
func validPaymentTime(t time.Time) bool {
	return !t.IsZero() && t.Year() >= 2000 && t.Year() <= 2100 && t.Nanosecond()%1000 == 0
}

// The receipt preserves the exact first result. Existing payment history is
// immutable: a stale or edited client cannot silently erase a paid occurrence.
func (s *Service) PushBill(ctx context.Context, user string, in BillSyncMutation, dataset string) (BillSyncRecord, error) {
	var result BillSyncRecord
	if err := in.Validate(); err != nil {
		return result, err
	}
	body, _ := json.Marshal(in)
	hash := sha256.Sum256(body)
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return result, err
	}
	defer tx.Rollback(ctx)
	if err = checkSyncDataset(ctx, tx, dataset, true); err != nil {
		return result, err
	}
	lock := sha256.Sum256([]byte(user + ":bill:" + in.OperationID))
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, int64(binary.BigEndian.Uint64(lock[:8]))); err != nil {
		return result, dbError(err)
	}
	var oldHash, raw []byte
	err = tx.QueryRow(ctx, `SELECT request_hash,response FROM bill_sync_receipts WHERE user_id=$1 AND operation_id=$2`, user, in.OperationID).Scan(&oldHash, &raw)
	if err == nil {
		if !bytes.Equal(oldHash, hash[:]) {
			return result, ErrConflict
		}
		if err = json.Unmarshal(raw, &result); err != nil {
			return result, err
		}
		return result, dbError(tx.Commit(ctx))
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return result, err
	}
	var version int64
	err = tx.QueryRow(ctx, `SELECT version FROM bills WHERE user_id=$1 AND id=$2 FOR UPDATE`, user, in.ID).Scan(&version)
	exists := err == nil
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return result, err
	}
	if exists && version != in.BaseVersion || !exists && in.BaseVersion != 0 {
		return result, ErrConflict
	}
	if in.Deleted {
		_, err = tx.Exec(ctx, `UPDATE bills SET deleted_at=now() WHERE user_id=$1 AND id=$2`, user, in.ID)
	} else {
		p := in.Payload
		if exists {
			rows, e := tx.Query(ctx, `SELECT `+paymentColumns+` FROM bill_payments WHERE user_id=$1 AND bill_id=$2`, user, in.ID)
			if e != nil {
				return result, e
			}
			old := []Payment{}
			for rows.Next() {
				v, e := scanPayment(rows)
				if e != nil {
					rows.Close()
					return result, e
				}
				old = append(old, v)
			}
			e = rows.Err()
			rows.Close()
			if e != nil {
				return result, e
			}
			for _, v := range old {
				found := false
				for _, n := range p.Payments {
					if n.ID == v.ID && n.BillID == v.BillID && n.DueAt.Equal(v.DueAt) && n.PaidAt.Equal(v.PaidAt) && n.AmountMinor == v.AmountMinor && n.CurrencyCode == v.CurrencyCode {
						found = true
						break
					}
				}
				if !found {
					return result, ErrConflict
				}
			}
			_, err = tx.Exec(ctx, `UPDATE bills SET name=$3,amount_minor=$4,currency_code=$5,due_at=$6,timezone=$7,recurrence=$8,recurrence_day=$9,reminder_minutes=$10,status=$11,paid_at=$12,deleted_at=NULL WHERE user_id=$1 AND id=$2`, user, in.ID, p.Name, p.AmountMinor, p.CurrencyCode, p.DueAt, p.Timezone, p.Recurrence, p.RecurrenceDay, p.ReminderMinutes, p.Status, p.PaidAt)
		} else {
			_, err = tx.Exec(ctx, `INSERT INTO bills(id,user_id,name,amount_minor,currency_code,due_at,timezone,recurrence,recurrence_day,reminder_minutes,status,paid_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`, in.ID, user, p.Name, p.AmountMinor, p.CurrencyCode, p.DueAt, p.Timezone, p.Recurrence, p.RecurrenceDay, p.ReminderMinutes, p.Status, p.PaidAt)
		}
		if err != nil {
			return result, dbError(err)
		}
		added := false
		for _, payment := range p.Payments {
			// A conflicting ID owned by another bill/account is never adopted.
			var existing Payment
			existing, e := scanPayment(tx.QueryRow(ctx, `SELECT `+paymentColumns+` FROM bill_payments WHERE user_id=$1 AND id=$2`, user, payment.ID))
			if e == nil {
				if existing.BillID != in.ID {
					return result, ErrConflict
				}
				continue
			}
			if e != ErrNotFound {
				return result, e
			}
			_, err = tx.Exec(ctx, `INSERT INTO bill_payments(id,user_id,bill_id,due_at,amount_minor,currency_code,paid_at) VALUES($1,$2,$3,$4,$5,$6,$7)`, payment.ID, user, in.ID, payment.DueAt, payment.AmountMinor, payment.CurrencyCode, payment.PaidAt)
			if err != nil {
				return result, dbError(err)
			}
			added = true
		}
		if added {
			_, err = tx.Exec(ctx, `UPDATE bills SET updated_at=clock_timestamp() WHERE user_id=$1 AND id=$2`, user, in.ID)
		}
	}
	if err != nil {
		return result, dbError(err)
	}
	if err = tx.QueryRow(ctx, `SELECT bill_sync_record(b) FROM bills b WHERE user_id=$1 AND id=$2`, user, in.ID).Scan(&raw); err != nil {
		return result, dbError(err)
	}
	if err = json.Unmarshal(raw, &result); err != nil {
		return result, err
	}
	if _, err = tx.Exec(ctx, `INSERT INTO bill_sync_receipts(user_id,operation_id,request_hash,response) VALUES($1,$2,$3,$4)`, user, in.OperationID, hash[:], raw); err != nil {
		return result, dbError(err)
	}
	return result, dbError(tx.Commit(ctx))
}

func (s *Service) GetSyncBill(ctx context.Context, user, id, dataset string) (BillSyncRecord, error) {
	var result BillSyncRecord
	var raw []byte
	if !ValidID(id) {
		return result, ErrInvalid
	}
	tx, err := s.Pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return result, err
	}
	defer tx.Rollback(ctx)
	if err = checkSyncDataset(ctx, tx, dataset, false); err != nil {
		return result, err
	}
	if err = tx.QueryRow(ctx, `SELECT bill_sync_record(b) FROM bills b WHERE user_id=$1 AND id=$2`, user, id).Scan(&raw); err != nil {
		return result, dbError(err)
	}
	if err = json.Unmarshal(raw, &result); err != nil {
		return result, err
	}
	return result, tx.Commit(ctx)
}
func (s *Service) PullBills(ctx context.Context, user string, after int64, limit int, dataset string) (BillSyncPage, error) {
	page := BillSyncPage{Items: []BillSyncChange{}}
	if after < 0 || after > MaxAmount || limit < 1 || limit > 100 {
		return page, ErrInvalid
	}
	tx, err := s.Pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return page, err
	}
	defer tx.Rollback(ctx)
	if err = checkSyncDataset(ctx, tx, dataset, false); err != nil {
		return page, err
	}
	var clock int64
	if err = tx.QueryRow(ctx, `SELECT COALESCE((SELECT seq FROM bill_sync_clock WHERE user_id=$1),0)`, user).Scan(&clock); err != nil {
		return page, err
	}
	if after > clock {
		return page, ErrSyncReset
	}
	rows, err := tx.Query(ctx, `SELECT seq,record FROM bill_changes WHERE user_id=$1 AND seq>$2 ORDER BY seq LIMIT $3`, user, after, limit+1)
	if err != nil {
		return page, err
	}
	defer rows.Close()
	for rows.Next() {
		var item BillSyncChange
		var raw []byte
		if err = rows.Scan(&item.Sequence, &raw); err != nil {
			return page, err
		}
		if err = json.Unmarshal(raw, &item.Record); err != nil {
			return page, err
		}
		page.Items = append(page.Items, item)
	}
	if err = rows.Err(); err != nil {
		return page, err
	}
	page.HasMore = len(page.Items) > limit
	page.Cursor = clock
	if page.HasMore {
		page.Items = page.Items[:limit]
		page.Cursor = page.Items[len(page.Items)-1].Sequence
	}
	return page, tx.Commit(ctx)
}
