package service

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"github.com/jackc/pgx/v5"
	"time"
)

var ErrMailDisabled = errors.New("account email not configured")

// ConfigureMail is called before serving requests. The key never leaves the
// process and must be shared by API/worker instances, outside database backups.
func (s *Service) ConfigureMail(key []byte) error {
	if len(key) != 32 {
		return ErrInvalid
	}
	s.mailKey = append([]byte(nil), key...)
	return nil
}
func mailCipher(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}
func mailAAD(id, recipient, kind string) []byte {
	return []byte(id + "\x00" + recipient + "\x00" + kind)
}
func encryptMail(key []byte, id, recipient, kind, body string) ([]byte, error) {
	aead, err := mailCipher(key)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err = rand.Read(nonce); err != nil {
		return nil, err
	}
	return aead.Seal(nonce, nonce, []byte(body), mailAAD(id, recipient, kind)), nil
}
func validAccountToken(token string) bool {
	raw, err := base64.RawURLEncoding.DecodeString(token)
	return err == nil && len(raw) == 32 && len(token) == 43
}

// Requests return the same success for existing and unknown reset addresses.
// Only the account's stored address can receive a message.
func (s *Service) RequestPasswordReset(ctx context.Context, email string) error {
	email, err := NormalizeEmail(email)
	if err != nil {
		return err
	}
	if len(s.mailKey) != 32 {
		return ErrMailDisabled
	}
	var user string
	err = s.Pool.QueryRow(ctx, `SELECT id::text FROM users WHERE email=$1`, email).Scan(&user)
	if err == pgx.ErrNoRows {
		return nil
	}
	if err != nil {
		return err
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err = tx.QueryRow(ctx, `SELECT email FROM users WHERE id=$1 FOR UPDATE`, user).Scan(&email); err != nil {
		return dbError(err)
	}
	if err = s.queueAccountMail(ctx, tx, user, email, "reset"); err != nil {
		return err
	}
	return dbError(tx.Commit(ctx))
}
func (s *Service) RequestEmailVerification(ctx context.Context, user, session string) error {
	if len(s.mailKey) != 32 {
		return ErrMailDisabled
	}
	tx, _, err := s.beginSessionMutation(ctx, user, session)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var email string
	var verified bool
	if err = tx.QueryRow(ctx, `SELECT email,email_verified FROM users WHERE id=$1`, user).Scan(&email, &verified); err != nil {
		return err
	}
	if verified {
		return tx.Commit(ctx)
	}
	if err = s.queueAccountMail(ctx, tx, user, email, "verify"); err != nil {
		return err
	}
	return dbError(tx.Commit(ctx))
}
func (s *Service) queueAccountMail(ctx context.Context, tx pgx.Tx, user, email, kind string) error {
	var secret [32]byte
	if _, err := rand.Read(secret[:]); err != nil {
		return err
	}
	token := base64.RawURLEncoding.EncodeToString(secret[:])
	id := NewID()
	ttl := 30 * time.Minute
	purpose := "pemulihan kata sandi"
	if kind == "verify" {
		ttl = 24 * time.Hour
		purpose = "verifikasi email"
	}
	body := fmt.Sprintf("Kode %s Catat Uang:\r\n\r\n%s\r\n\r\nMasukkan kode ini hanya di aplikasi Catat Uang pada server yang Anda gunakan. Kode berlaku %s dan hanya sekali pakai. Jika Anda tidak meminta ini, abaikan pesan. Jangan membagikan kode.\r\n", purpose, token, ttl)
	encrypted, err := encryptMail(s.mailKey, id, email, kind, body)
	if err != nil {
		return err
	}
	// Reissuing supersedes older tokens and queued mail of the same purpose.
	if _, err = tx.Exec(ctx, `DELETE FROM account_tokens WHERE user_id=$1 AND kind=$2`, user, kind); err != nil {
		return err
	}
	if _, err = tx.Exec(ctx, `DELETE FROM mail_outbox WHERE user_id=$1 AND kind=$2`, user, kind); err != nil {
		return err
	}
	expires := time.Now().UTC().Add(ttl)
	if _, err = tx.Exec(ctx, `INSERT INTO account_tokens(token_hash,user_id,kind,expires_at) VALUES($1,$2,$3,$4)`, tokenHash(token), user, kind, expires); err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `INSERT INTO mail_outbox(id,user_id,kind,recipient,encrypted_body,expires_at) VALUES($1,$2,$3,$4,$5,$6)`, id, user, kind, email, encrypted, expires)
	return err
}
func (s *Service) ConsumeAccountToken(ctx context.Context, token, kind, newPassword string) error {
	if !validAccountToken(token) || kind != "verify" && kind != "reset" || kind == "reset" && !validPassword(newPassword) {
		return ErrInvalid
	}
	var user string
	err := s.Pool.QueryRow(ctx, `SELECT user_id::text FROM account_tokens WHERE token_hash=$1 AND kind=$2 AND expires_at>clock_timestamp()`, tokenHash(token), kind).Scan(&user)
	if err == pgx.ErrNoRows {
		return ErrInvalid
	}
	if err != nil {
		return err
	}
	replacement := ""
	if kind == "reset" {
		select {
		case s.hashSlots <- struct{}{}:
			defer func() { <-s.hashSlots }()
		case <-ctx.Done():
			return ctx.Err()
		}
		replacement = HashPassword(newPassword)
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.Background())
	var locked string
	if err = tx.QueryRow(ctx, `SELECT id::text FROM users WHERE id=$1 FOR UPDATE`, user).Scan(&locked); err != nil {
		return dbError(err)
	}
	var valid bool
	err = tx.QueryRow(ctx, `SELECT expires_at>clock_timestamp() FROM account_tokens WHERE user_id=$1 AND token_hash=$2 AND kind=$3 FOR UPDATE`, user, tokenHash(token), kind).Scan(&valid)
	if err == pgx.ErrNoRows || err == nil && !valid {
		return ErrInvalid
	}
	if err != nil {
		return err
	}
	if kind == "verify" {
		_, err = tx.Exec(ctx, `UPDATE users SET email_verified=true WHERE id=$1`, user)
	} else {
		_, err = tx.Exec(ctx, `UPDATE users SET password_hash=$2 WHERE id=$1`, user, replacement)
		if err == nil {
			_, err = tx.Exec(ctx, `DELETE FROM sessions WHERE user_id=$1`, user)
		}
	}
	if err != nil {
		return dbError(err)
	}
	if _, err = tx.Exec(ctx, `DELETE FROM account_tokens WHERE user_id=$1 AND kind=$2`, user, kind); err != nil {
		return err
	}
	if _, err = tx.Exec(ctx, `DELETE FROM mail_outbox WHERE user_id=$1 AND kind=$2`, user, kind); err != nil {
		return err
	}
	return dbError(tx.Commit(ctx))
}

type PendingMail struct{ ID, LeaseID, Recipient, Kind, Body string }

func (s *Service) ClaimMail(ctx context.Context) (*PendingMail, error) {
	if len(s.mailKey) != 32 {
		return nil, ErrMailDisabled
	}
	var message PendingMail
	var encrypted []byte
	message.LeaseID = NewID()
	err := s.Pool.QueryRow(ctx, `UPDATE mail_outbox SET lease_id=$1,lease_until=clock_timestamp()+interval '2 minutes',attempts=attempts+1 WHERE id=(SELECT id FROM mail_outbox WHERE expires_at>clock_timestamp() AND available_at<=clock_timestamp() AND (lease_until IS NULL OR lease_until<=clock_timestamp()) AND attempts<8 ORDER BY available_at,id FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING id::text,recipient,kind,encrypted_body`, message.LeaseID).Scan(&message.ID, &message.Recipient, &message.Kind, &encrypted)
	if err == pgx.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	aead, err := mailCipher(s.mailKey)
	if err != nil {
		return nil, err
	}
	if len(encrypted) < aead.NonceSize()+aead.Overhead() {
		return nil, ErrInvalid
	}
	plain, err := aead.Open(nil, encrypted[:aead.NonceSize()], encrypted[aead.NonceSize():], mailAAD(message.ID, message.Recipient, message.Kind))
	if err != nil {
		return nil, ErrInvalid
	}
	message.Body = string(plain)
	return &message, nil
}
func (s *Service) FinishMail(ctx context.Context, message PendingMail, sent bool) error {
	if sent {
		_, err := s.Pool.Exec(ctx, `DELETE FROM mail_outbox WHERE id=$1 AND lease_id=$2`, message.ID, message.LeaseID)
		return err
	}
	_, err := s.Pool.Exec(ctx, `UPDATE mail_outbox SET lease_id=NULL,lease_until=NULL,available_at=clock_timestamp()+make_interval(secs=>LEAST(3600,30*power(2,attempts)::integer)) WHERE id=$1 AND lease_id=$2`, message.ID, message.LeaseID)
	return err
}
