package service

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"net/mail"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/argon2"
)

const hashPrefix = "$argon2id$v=19$m=65536,t=3,p=1$"
const SessionLifetime = 24 * time.Hour

type Credentials struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}
type User struct {
	ID    string `json:"id"`
	Email string `json:"email"`
}
type Session struct {
	AccessToken string    `json:"access_token"`
	TokenType   string    `json:"token_type"`
	ExpiresAt   time.Time `json:"expires_at"`
	User        User      `json:"user"`
}

func NormalizeEmail(email string) (string, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	address, err := mail.ParseAddress(email)
	if err != nil || address.Address != email || len(email) > 254 || !strings.Contains(email, ".") || strings.ContainsAny(email, "\r\n") {
		return "", ErrInvalid
	}
	for _, r := range email {
		if r > 127 {
			return "", ErrInvalid
		}
	}
	return email, nil
}
func validPassword(password string) bool {
	return utf8.ValidString(password) && utf8.RuneCountInString(password) >= 15 && len(password) <= 128
}

func HashPassword(password string) string {
	var salt [16]byte
	_, _ = rand.Read(salt[:])
	key := argon2.IDKey([]byte(password), salt[:], 3, 64*1024, 1, 32)
	return hashPrefix + base64.RawStdEncoding.EncodeToString(salt[:]) + "$" + base64.RawStdEncoding.EncodeToString(key)
}
func CheckPassword(hash, password string) bool {
	if !strings.HasPrefix(hash, hashPrefix) {
		return false
	}
	parts := strings.Split(strings.TrimPrefix(hash, hashPrefix), "$")
	if len(parts) != 2 {
		return false
	}
	salt, e1 := base64.RawStdEncoding.DecodeString(parts[0])
	expected, e2 := base64.RawStdEncoding.DecodeString(parts[1])
	if e1 != nil || e2 != nil || len(salt) != 16 || len(expected) != 32 {
		return false
	}
	actual := argon2.IDKey([]byte(password), salt, 3, 64*1024, 1, 32)
	return subtle.ConstantTimeCompare(actual, expected) == 1
}
func tokenHash(token string) []byte { sum := sha256.Sum256([]byte(token)); return sum[:] }

// Rate limits are shared by API instances. Forwarded headers are not trusted.
func (s *Service) LimitAuth(ctx context.Context, ip, email string) error {
	for _, scope := range []string{"ip:" + ip, "account:" + email} {
		sum := sha256.Sum256([]byte(scope))
		var count int
		err := s.Pool.QueryRow(ctx, `INSERT INTO auth_rate_limits(key_hash,attempts,expires_at) VALUES($1,1,now()+interval '15 minutes')
   ON CONFLICT(key_hash) DO UPDATE SET attempts=CASE WHEN auth_rate_limits.expires_at<=now() THEN 1 ELSE LEAST(auth_rate_limits.attempts+1,1000) END,
   expires_at=CASE WHEN auth_rate_limits.expires_at<=now() THEN now()+interval '15 minutes' ELSE auth_rate_limits.expires_at END RETURNING attempts`, sum[:]).Scan(&count)
		if err != nil {
			return err
		}
		if count > 20 {
			return ErrRateLimited
		}
	}
	return nil
}

func (s *Service) Authenticate(ctx context.Context, input Credentials, register bool) (Session, error) {
	email, err := NormalizeEmail(input.Email)
	if err != nil || !validPassword(input.Password) {
		return Session{}, ErrInvalid
	}
	select {
	case s.hashSlots <- struct{}{}:
		defer func() { <-s.hashSlots }()
	case <-ctx.Done():
		return Session{}, ctx.Err()
	}
	user := User{Email: email}
	var hash string
	if register {
		user.ID = NewID()
		hash = HashPassword(input.Password)
	} else {
		err = s.Pool.QueryRow(ctx, "SELECT id::text,password_hash FROM users WHERE email=$1", email).Scan(&user.ID, &hash)
		if err != nil && err != pgx.ErrNoRows {
			return Session{}, err
		}
		if err == pgx.ErrNoRows {
			// Equal-cost dummy verification for an unknown account.
			_ = argon2.IDKey([]byte(input.Password), make([]byte, 16), 3, 64*1024, 1, 32)
			return Session{}, ErrUnauthorized
		}
		if !CheckPassword(hash, input.Password) {
			return Session{}, ErrUnauthorized
		}
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return Session{}, err
	}
	defer tx.Rollback(context.Background())
	if register {
		if _, err = tx.Exec(ctx, "INSERT INTO users(id,email,password_hash) VALUES($1,$2,$3)", user.ID, email, hash); err != nil {
			return Session{}, dbError(err)
		}
		if _, err = tx.Exec(ctx, "INSERT INTO user_settings(user_id) VALUES($1)", user.ID); err != nil {
			return Session{}, err
		}
	} else {
		// Serialize session issuance with password changes. A verification of an
		// old hash must not create a fresh session after that hash was replaced.
		var current string
		if err = tx.QueryRow(ctx, `SELECT password_hash FROM users WHERE id=$1 FOR UPDATE`, user.ID).Scan(&current); err != nil {
			return Session{}, dbError(err)
		}
		if current != hash {
			return Session{}, ErrUnauthorized
		}
	}
	var secret [32]byte
	_, _ = rand.Read(secret[:])
	token := base64.RawURLEncoding.EncodeToString(secret[:])
	var expires time.Time
	if err = tx.QueryRow(ctx, "INSERT INTO sessions(token_hash,user_id,expires_at) VALUES($1,$2,now()+interval '24 hours') RETURNING expires_at", tokenHash(token), user.ID).Scan(&expires); err != nil {
		return Session{}, err
	}
	if err = tx.Commit(ctx); err != nil {
		return Session{}, err
	}
	return Session{token, "Bearer", expires, user}, nil
}

func (s *Service) CurrentUser(ctx context.Context, token string) (User, error) {
	if len(token) != 43 {
		return User{}, ErrUnauthorized
	}
	if b, err := base64.RawURLEncoding.DecodeString(token); err != nil || len(b) != 32 {
		return User{}, ErrUnauthorized
	}
	var u User
	err := s.Pool.QueryRow(ctx, `SELECT u.id::text,u.email FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=$1 AND s.expires_at>now()`, tokenHash(token)).Scan(&u.ID, &u.Email)
	if err == pgx.ErrNoRows {
		return u, ErrUnauthorized
	}
	return u, err
}
func (s *Service) Logout(ctx context.Context, user, token string, all bool) error {
	tx, _, err := s.beginSessionMutation(ctx, user, token)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.Background())
	if all {
		_, err = tx.Exec(ctx, "DELETE FROM sessions WHERE user_id=$1", user)
	} else {
		_, err = tx.Exec(ctx, "DELETE FROM sessions WHERE user_id=$1 AND token_hash=$2", user, tokenHash(token))
	}
	if err != nil {
		return dbError(err)
	}
	return dbError(tx.Commit(ctx))
}

// Maintenance is an explicit operator action, not a background request side effect.
func (s *Service) Cleanup(ctx context.Context) error {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.Background())
	for _, table := range []string{"sessions", "auth_rate_limits"} {
		if _, err = tx.Exec(ctx, fmt.Sprintf("DELETE FROM %s WHERE expires_at <= now()", table)); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}
