package service

import (
	"context"
	"github.com/jackc/pgx/v5"
)

// Rotation is an administrative restore step, never a client-triggered reset.
func (s *Service) SyncDataset(ctx context.Context) (string, error) {
	var id string
	err := s.Pool.QueryRow(ctx, `SELECT dataset_id::text FROM sync_dataset WHERE id=1`).Scan(&id)
	return id, err
}

func checkSyncDataset(ctx context.Context, tx pgx.Tx, expected string, lock bool) error {
	if !ValidID(expected) {
		return ErrInvalid
	}
	query := `SELECT dataset_id::text FROM sync_dataset WHERE id=1`
	// A rotation must wait for accepted writes to commit. Pull uses a consistent
	// repeatable-read snapshot and may safely finish on the previous generation.
	if lock {
		query += ` FOR SHARE`
	}
	var actual string
	if err := tx.QueryRow(ctx, query).Scan(&actual); err != nil {
		return err
	}
	if actual != expected {
		return ErrSyncReset
	}
	return nil
}
