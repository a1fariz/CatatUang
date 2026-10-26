package service

import (
	"context"
	"github.com/jackc/pgx/v5"
	"time"
)

type AccountSession struct {
	ID        string    `json:"id"`
	Current   bool      `json:"current"`
	CreatedAt time.Time `json:"created_at"`
	ExpiresAt time.Time `json:"expires_at"`
}

func (s *Service) ListSessions(ctx context.Context, user, token string, options ListOptions) ([]AccountSession, error) {
	if options.Limit < 1 || options.Limit > 100 || options.Offset < 0 || options.Offset > 10000 {
		return nil, ErrInvalid
	}
	rows, err := s.Pool.Query(ctx, `SELECT id::text,token_hash=$2,created_at,expires_at FROM sessions
 WHERE user_id=$1 AND expires_at>clock_timestamp()
 ORDER BY (token_hash=$2) DESC,created_at DESC,id DESC LIMIT $3 OFFSET $4`, user, tokenHash(token), options.Limit+1, options.Offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []AccountSession{}
	for rows.Next() {
		var value AccountSession
		if err = rows.Scan(&value.ID, &value.Current, &value.CreatedAt, &value.ExpiresAt); err != nil {
			return nil, err
		}
		result = append(result, value)
	}
	return result, rows.Err()
}

// Session mutations share the user-row lock with login/password changes, then
// revalidate the authorizing session so a revoked token cannot act after waiting.
func (s *Service) beginSessionMutation(ctx context.Context, user, token string) (pgx.Tx, string, error) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return nil, "", err
	}
	fail := func(err error) (pgx.Tx, string, error) { _ = tx.Rollback(context.Background()); return nil, "", err }
	var exists string
	err = tx.QueryRow(ctx, `SELECT id::text FROM users WHERE id=$1 FOR UPDATE`, user).Scan(&exists)
	if err == pgx.ErrNoRows {
		return fail(ErrUnauthorized)
	}
	if err != nil {
		return fail(dbError(err))
	}
	var currentID string
	var valid bool
	err = tx.QueryRow(ctx, `SELECT id::text,expires_at>clock_timestamp() FROM sessions WHERE user_id=$1 AND token_hash=$2 FOR UPDATE`, user, tokenHash(token)).Scan(&currentID, &valid)
	if err == pgx.ErrNoRows || err == nil && !valid {
		return fail(ErrUnauthorized)
	}
	if err != nil {
		return fail(dbError(err))
	}
	return tx, currentID, nil
}

func (s *Service) RevokeSession(ctx context.Context, user, token, id string) error {
	if !ValidID(id) {
		return ErrInvalid
	}
	tx, currentID, err := s.beginSessionMutation(ctx, user, token)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.Background())
	if currentID == id {
		return ErrInvalid
	}
	tag, err := tx.Exec(ctx, `DELETE FROM sessions WHERE user_id=$1 AND id=$2 AND expires_at>clock_timestamp()`, user, id)
	if err != nil {
		return dbError(err)
	}
	if tag.RowsAffected() != 1 {
		return ErrNotFound
	}
	return dbError(tx.Commit(ctx))
}
