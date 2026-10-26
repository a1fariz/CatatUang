package service

import (
	"context"
	"github.com/jackc/pgx/v5"
)

type PasswordChange struct {
	CurrentPassword string `json:"current_password"`
	NewPassword     string `json:"new_password"`
}

func (in PasswordChange) Validate() error {
	if !validPassword(in.CurrentPassword) || !validPassword(in.NewPassword) || in.CurrentPassword == in.NewPassword {
		return ErrInvalid
	}
	return nil
}

// The current session survives with its original expiry. All other sessions
// are revoked atomically with the password change.
func (s *Service) ChangePassword(ctx context.Context, user, token string, in PasswordChange) error {
	if err := in.Validate(); err != nil {
		return err
	}
	select {
	case s.hashSlots <- struct{}{}:
		defer func() { <-s.hashSlots }()
	case <-ctx.Done():
		return ctx.Err()
	}
	var original string
	if err := s.Pool.QueryRow(ctx, `SELECT password_hash FROM users WHERE id=$1`, user).Scan(&original); err != nil {
		return dbError(err)
	}
	if !CheckPassword(original, in.CurrentPassword) {
		return ErrInvalid
	}
	replacement := HashPassword(in.NewPassword)
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.Background())
	var current string
	if err = tx.QueryRow(ctx, `SELECT password_hash FROM users WHERE id=$1 FOR UPDATE`, user).Scan(&current); err != nil {
		return dbError(err)
	}
	if current != original {
		return ErrConflict
	}
	var sessionValid bool
	// Lock the retained session so logout cannot remove it between validation and
	// commit. Expiry is checked using wall-clock time after password hashing.
	err = tx.QueryRow(ctx, `SELECT expires_at>clock_timestamp() FROM sessions WHERE user_id=$1 AND token_hash=$2 FOR UPDATE`, user, tokenHash(token)).Scan(&sessionValid)
	if err == pgx.ErrNoRows || err == nil && !sessionValid {
		return ErrUnauthorized
	}
	if err != nil {
		return dbError(err)
	}
	if _, err = tx.Exec(ctx, `UPDATE users SET password_hash=$2 WHERE id=$1`, user, replacement); err != nil {
		return dbError(err)
	}
	if _, err = tx.Exec(ctx, `DELETE FROM sessions WHERE user_id=$1 AND token_hash<>$2`, user, tokenHash(token)); err != nil {
		return dbError(err)
	}
	if _, err = tx.Exec(ctx, `DELETE FROM account_tokens WHERE user_id=$1 AND kind='reset'`, user); err != nil {
		return err
	}
	if _, err = tx.Exec(ctx, `DELETE FROM mail_outbox WHERE user_id=$1 AND kind='reset'`, user); err != nil {
		return err
	}
	return dbError(tx.Commit(ctx))
}
