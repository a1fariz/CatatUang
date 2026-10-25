package service

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"

	"github.com/jackc/pgx/v5"
)

var ErrSyncReset = errors.New("sync cursor is ahead of server")

type SyncRecord struct {
	Transaction
	Deleted bool `json:"deleted"`
}
type SyncMutation struct {
	OperationID string            `json:"operation_id"`
	ID          string            `json:"id"`
	BaseVersion int64             `json:"base_version"`
	Deleted     bool              `json:"deleted"`
	Payload     *TransactionInput `json:"payload"`
}
type SyncChange struct {
	Sequence int64      `json:"sequence"`
	Record   SyncRecord `json:"record"`
}
type SyncPage struct {
	Items   []SyncChange `json:"items"`
	Cursor  int64        `json:"cursor"`
	HasMore bool         `json:"has_more"`
}

func (in SyncMutation) Validate() error {
	if !ValidID(in.OperationID) || !ValidID(in.ID) || in.BaseVersion < 0 || in.BaseVersion >= MaxAmount {
		return ErrInvalid
	}
	if in.Deleted {
		if in.Payload != nil || in.BaseVersion == 0 {
			return ErrInvalid
		}
		return nil
	}
	if in.Payload == nil {
		return ErrInvalid
	}
	return in.Payload.Validate()
}

// A receipt and its mutation commit together. Retrying an operation returns its
// original result, even if another device has subsequently edited the record.
func (s *Service) PushTransaction(ctx context.Context, user string, in SyncMutation, dataset string) (SyncRecord, error) {
	var result SyncRecord
	if err := in.Validate(); err != nil {
		return result, err
	}
	body, err := json.Marshal(in)
	if err != nil {
		return result, err
	}
	hash := sha256.Sum256(body)
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return result, err
	}
	defer tx.Rollback(ctx)
	if err = checkSyncDataset(ctx, tx, dataset, true); err != nil {
		return result, err
	}
	lock := sha256.Sum256([]byte(user + ":" + in.OperationID))
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, int64(binary.BigEndian.Uint64(lock[:8]))); err != nil {
		return result, dbError(err)
	}
	var oldHash, response []byte
	err = tx.QueryRow(ctx, `SELECT request_hash,response FROM transaction_sync_receipts WHERE user_id=$1 AND operation_id=$2`, user, in.OperationID).Scan(&oldHash, &response)
	if err == nil {
		if !bytes.Equal(oldHash, hash[:]) {
			return result, ErrConflict
		}
		if err = json.Unmarshal(response, &result); err != nil {
			return result, err
		}
		return result, tx.Commit(ctx)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return result, err
	}
	var version int64
	err = tx.QueryRow(ctx, `SELECT version FROM transactions WHERE user_id=$1 AND id=$2 FOR UPDATE`, user, in.ID).Scan(&version)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return result, err
	}
	exists := err == nil
	if (!exists && in.BaseVersion != 0) || (exists && version != in.BaseVersion) {
		return result, ErrConflict
	}
	var row pgx.Row
	if !exists {
		p := in.Payload
		row = tx.QueryRow(ctx, `INSERT INTO transactions(id,user_id,type,amount_minor,currency_code,category,occurred_on,note) VALUES($1,$2,$3,$4,$5,$6,$7,$8) RETURNING transaction_sync_record(transactions)`, in.ID, user, p.Type, p.AmountMinor, p.CurrencyCode, p.Category, p.OccurredOn, p.Note)
	} else if in.Deleted {
		row = tx.QueryRow(ctx, `UPDATE transactions SET deleted_at=now() WHERE user_id=$1 AND id=$2 RETURNING transaction_sync_record(transactions)`, user, in.ID)
	} else {
		p := in.Payload
		row = tx.QueryRow(ctx, `UPDATE transactions SET type=$3,amount_minor=$4,currency_code=$5,category=$6,occurred_on=$7,note=$8,deleted_at=NULL WHERE user_id=$1 AND id=$2 RETURNING transaction_sync_record(transactions)`, user, in.ID, p.Type, p.AmountMinor, p.CurrencyCode, p.Category, p.OccurredOn, p.Note)
	}
	if err = row.Scan(&response); err != nil {
		return result, dbError(err)
	}
	if err = json.Unmarshal(response, &result); err != nil {
		return result, err
	}
	if _, err = tx.Exec(ctx, `INSERT INTO transaction_sync_receipts(user_id,operation_id,request_hash,response) VALUES($1,$2,$3,$4)`, user, in.OperationID, hash[:], response); err != nil {
		return result, dbError(err)
	}
	return result, dbError(tx.Commit(ctx))
}

// Tombstones are deliberately readable here, unlike the ordinary CRUD API.
func (s *Service) GetSyncTransaction(ctx context.Context, user, id, dataset string) (SyncRecord, error) {
	var result SyncRecord
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
	err = tx.QueryRow(ctx, `SELECT transaction_sync_record(t) FROM transactions t WHERE user_id=$1 AND id=$2`, user, id).Scan(&raw)
	if err != nil {
		return result, dbError(err)
	}
	err = json.Unmarshal(raw, &result)
	if err != nil {
		return result, err
	}
	return result, tx.Commit(ctx)
}

func (s *Service) PullTransactions(ctx context.Context, user string, after int64, limit int, dataset string) (SyncPage, error) {
	page := SyncPage{Items: []SyncChange{}}
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
	err = tx.QueryRow(ctx, `SELECT COALESCE((SELECT seq FROM transaction_sync_clock WHERE user_id=$1),0)`, user).Scan(&clock)
	if err != nil {
		return page, err
	}
	if after > clock {
		return page, ErrSyncReset
	}
	rows, err := tx.Query(ctx, `SELECT seq,record FROM transaction_changes WHERE user_id=$1 AND seq>$2 ORDER BY seq LIMIT $3`, user, after, limit+1)
	if err != nil {
		return page, err
	}
	defer rows.Close()
	for rows.Next() {
		var item SyncChange
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
