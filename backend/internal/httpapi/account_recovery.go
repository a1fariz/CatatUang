package httpapi

import (
	"catatuang/backend/internal/service"
	"context"
	"errors"
	"net"
	"net/http"
	"strings"
	"time"
)

func (a *API) accountRecovery(w http.ResponseWriter, r *http.Request, id string, verifyRequest bool, session string) {
	if r.URL.RawQuery != "" {
		a.serviceError(w, r, id, service.ErrInvalid)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), a.dbTimeout+10*time.Second)
	defer cancel()
	r = r.WithContext(ctx)
	ip, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		ip = r.RemoteAddr
	}
	scope := "account-recovery:" + ip
	var action func() error
	accepted := false
	if verifyRequest {
		user, err := a.service.CurrentUser(ctx, session)
		if err != nil {
			a.serviceError(w, r, id, err)
			return
		}
		scope = "email-verification:" + ip
		if err = a.service.LimitAuth(ctx, scope, "email-verification:"+user.ID); err != nil {
			a.serviceError(w, r, id, err)
			return
		}
		action = func() error { return a.service.RequestEmailVerification(ctx, user.ID, session) }
		accepted = true
	} else if strings.HasSuffix(r.URL.Path, "/request") {
		var input struct {
			Email string `json:"email"`
		}
		if !a.decode(w, r, id, &input) {
			return
		}
		email, err := service.NormalizeEmail(input.Email)
		if err != nil {
			a.serviceError(w, r, id, err)
			return
		}
		if err = a.service.LimitAuth(ctx, "password-reset-request:"+ip, "password-reset-request:"+email); err != nil {
			a.serviceError(w, r, id, err)
			return
		}
		action = func() error { return a.service.RequestPasswordReset(ctx, email) }
		accepted = true
	} else {
		var input struct {
			Token       string `json:"token"`
			NewPassword string `json:"new_password"`
		}
		if !a.decode(w, r, id, &input) {
			return
		}
		if err = a.service.LimitAuth(ctx, scope, "account-token:"+input.Token); err != nil {
			a.serviceError(w, r, id, err)
			return
		}
		kind := "reset"
		if strings.Contains(r.URL.Path, "email-verification") {
			kind = "verify"
			if input.NewPassword != "" {
				a.serviceError(w, r, id, service.ErrInvalid)
				return
			}
		}
		action = func() error { return a.service.ConsumeAccountToken(ctx, input.Token, kind, input.NewPassword) }
	}
	err = action()
	if errors.Is(err, service.ErrMailDisabled) {
		a.fail(w, r, 503, "email_unavailable", "Layanan email belum dikonfigurasi. Coba lagi nanti.", id)
		return
	}
	if err != nil {
		a.serviceError(w, r, id, err)
		return
	}
	if accepted {
		a.json(w, r, 202, map[string]string{"message": "Jika permintaan memenuhi syarat, kode akan dikirim ke email akun. Periksa email dan masukkan kode di aplikasi."})
	} else {
		w.WriteHeader(204)
	}
}
