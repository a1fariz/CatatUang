package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"reflect"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"catatuang/backend/internal/service"
)

func (a *API) serveData(w http.ResponseWriter, r *http.Request, id string) bool {
	path := r.URL.Path
	if path == "/v1/auth/register" || path == "/v1/auth/login" {
		if !a.allow(w, r, id, "POST") {
			return true
		}
		a.auth(w, r, id, path == "/v1/auth/register")
		return true
	}
	parts := strings.Split(strings.TrimPrefix(path, "/"), "/")
	collection := len(parts) == 2 && parts[0] == "v1" && (parts[1] == "transactions" || parts[1] == "bills")
	entity := len(parts) >= 3 && len(parts) <= 4 && parts[0] == "v1" && (parts[1] == "transactions" || parts[1] == "bills") && service.ValidID(parts[2])
	billAction := entity && len(parts) == 4 && parts[1] == "bills" && (parts[3] == "pay" || parts[3] == "payments")
	if entity && len(parts) == 4 && !billAction {
		return false
	}
	me := path == "/v1/me"
	logout := path == "/v1/auth/logout" || path == "/v1/auth/logout-all"
	syncCollection := path == "/v1/sync/transactions"
	syncEntity := len(parts) == 4 && parts[0] == "v1" && parts[1] == "sync" && parts[2] == "transactions" && service.ValidID(parts[3])
	if !collection && !entity && !me && !logout && !syncCollection && !syncEntity {
		return false
	}
	methods := "GET, HEAD"
	if logout || billAction && parts[3] == "pay" {
		methods = "POST"
	} else if collection || syncCollection {
		methods = "GET, HEAD, POST"
	} else if entity && !billAction {
		methods = "GET, HEAD, PUT, DELETE"
	}
	if !a.allow(w, r, id, methods) {
		return true
	}
	ctx, cancel := context.WithTimeout(r.Context(), a.dbTimeout)
	defer cancel()
	r = r.WithContext(ctx)
	header := strings.Fields(r.Header.Get("Authorization"))
	if len(r.Header.Values("Authorization")) != 1 || len(header) != 2 || !strings.EqualFold(header[0], "Bearer") {
		a.serviceError(w, r, id, service.ErrUnauthorized)
		return true
	}
	user, err := a.service.CurrentUser(ctx, header[1])
	if err != nil {
		a.serviceError(w, r, id, err)
		return true
	}
	if me {
		a.json(w, r, 200, user)
		return true
	}
	if syncCollection || syncEntity {
		a.transactionSync(w, r, id, user.ID, syncEntity)
		return true
	}
	if logout {
		if err := a.service.Logout(ctx, user.ID, header[1], path == "/v1/auth/logout-all"); err != nil {
			a.serviceError(w, r, id, err)
		} else {
			w.WriteHeader(204)
		}
		return true
	}
	if billAction {
		if parts[3] == "payments" {
			o, err := listOptions(r, false)
			if err != nil {
				a.serviceError(w, r, id, err)
				return true
			}
			values, err := a.service.ListPayments(ctx, user.ID, parts[2], o)
			if err != nil {
				a.serviceError(w, r, id, err)
			} else {
				writeList(a, w, r, values, o)
			}
		} else {
			version, ok := a.version(w, r, id)
			if !ok {
				return true
			}
			var in struct {
				DueAt time.Time `json:"due_at"`
			}
			if !a.decode(w, r, id, &in) {
				return true
			}
			if len(r.Header.Values("Idempotency-Key")) != 1 {
				a.serviceError(w, r, id, service.ErrInvalid)
				return true
			}
			result, err := a.service.PayBill(ctx, user.ID, parts[2], r.Header.Get("Idempotency-Key"), version, in.DueAt)
			if err != nil {
				a.serviceError(w, r, id, err)
			} else {
				a.etag(w, result.Bill.Version)
				a.json(w, r, 200, result)
			}
		}
		return true
	}
	if collection && (r.Method == "GET" || r.Method == "HEAD") {
		o, err := listOptions(r, parts[1] == "transactions")
		if err != nil {
			a.serviceError(w, r, id, err)
			return true
		}
		if parts[1] == "transactions" {
			values, err := a.service.ListTransactions(ctx, user.ID, o)
			if err != nil {
				a.serviceError(w, r, id, err)
			} else {
				writeList(a, w, r, values, o)
			}
		} else {
			values, err := a.service.ListBills(ctx, user.ID, o)
			if err != nil {
				a.serviceError(w, r, id, err)
			} else {
				writeList(a, w, r, values, o)
			}
		}
		return true
	}
	entityID := ""
	if entity {
		entityID = parts[2]
	}
	version := int64(0)
	if entity && (r.Method == "PUT" || r.Method == "DELETE") {
		var ok bool
		version, ok = a.version(w, r, id)
		if !ok {
			return true
		}
	}
	if r.Method == "DELETE" {
		if err := a.service.Delete(ctx, parts[1], user.ID, entityID, version); err != nil {
			a.serviceError(w, r, id, err)
		} else {
			w.WriteHeader(204)
		}
		return true
	}
	if parts[1] == "transactions" {
		var value service.Transaction
		if r.Method == "GET" || r.Method == "HEAD" {
			value, err = a.service.GetTransaction(ctx, user.ID, entityID)
		} else {
			var in service.TransactionInput
			if !a.decode(w, r, id, &in) {
				return true
			}
			value, err = a.service.SaveTransaction(ctx, user.ID, entityID, version, in)
		}
		if err != nil {
			a.serviceError(w, r, id, err)
		} else {
			a.etag(w, value.Version)
			status := 200
			if collection {
				status = 201
				w.Header().Set("Location", "/v1/transactions/"+value.ID)
			}
			a.json(w, r, status, value)
		}
	} else {
		var value service.Bill
		if r.Method == "GET" || r.Method == "HEAD" {
			value, err = a.service.GetBill(ctx, user.ID, entityID)
		} else {
			var in service.BillInput
			if !a.decode(w, r, id, &in) {
				return true
			}
			value, err = a.service.SaveBill(ctx, user.ID, entityID, version, in)
		}
		if err != nil {
			a.serviceError(w, r, id, err)
		} else {
			a.etag(w, value.Version)
			status := 200
			if collection {
				status = 201
				w.Header().Set("Location", "/v1/bills/"+value.ID)
			}
			a.json(w, r, status, value)
		}
	}
	return true
}

func (a *API) auth(w http.ResponseWriter, r *http.Request, id string, register bool) {
	var input service.Credentials
	if !a.decode(w, r, id, &input) {
		return
	}
	email, err := service.NormalizeEmail(input.Email)
	if err != nil {
		a.serviceError(w, r, id, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), a.dbTimeout+10*time.Second)
	defer cancel()
	r = r.WithContext(ctx)
	ip, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		ip = r.RemoteAddr
	}
	if err = a.service.LimitAuth(ctx, ip, email); err != nil {
		a.serviceError(w, r, id, err)
		return
	}
	result, err := a.service.Authenticate(ctx, input, register)
	if err != nil {
		a.serviceError(w, r, id, err)
		return
	}
	status := 200
	if register {
		status = 201
	}
	a.json(w, r, status, result)
}
func (a *API) allow(w http.ResponseWriter, r *http.Request, id, methods string) bool {
	for _, method := range strings.Split(methods, ", ") {
		if r.Method == method {
			return true
		}
	}
	w.Header().Set("Allow", methods)
	a.fail(w, r, 405, "method_not_allowed", "Metode tidak diizinkan.", id)
	return false
}
func (a *API) etag(w http.ResponseWriter, version int64) {
	w.Header().Set("ETag", `"`+strconv.FormatInt(version, 10)+`"`)
}
func (a *API) version(w http.ResponseWriter, r *http.Request, id string) (int64, bool) {
	raw := r.Header.Get("If-Match")
	if raw == "" {
		a.fail(w, r, 428, "precondition_required", "Kirim versi data pada header If-Match.", id)
		return 0, false
	}
	n, err := strconv.ParseInt(strings.Trim(raw, `"`), 10, 64)
	if len(r.Header.Values("If-Match")) != 1 || err != nil || n < 1 || raw != `"`+strconv.FormatInt(n, 10)+`"` {
		a.fail(w, r, 400, "invalid_request", "If-Match harus berisi satu versi dalam tanda kutip.", id)
		return 0, false
	}
	return n, true
}
func (a *API) serviceError(w http.ResponseWriter, r *http.Request, id string, err error) {
	status, code, message := 500, "internal_error", "Terjadi kesalahan server."
	switch {
	case errors.Is(err, service.ErrSyncReset):
		status, code, message = 409, "sync_reset_required", "Posisi sinkronisasi lebih baru dari server. Perlu rekonsiliasi data."
	case errors.Is(err, service.ErrInvalid):
		status, code, message = 422, "invalid_input", "Periksa kembali data yang diisi."
	case errors.Is(err, service.ErrUnauthorized):
		status, code, message = 401, "unauthorized", "Kredensial atau sesi tidak valid."
		w.Header().Set("WWW-Authenticate", "Bearer")
	case errors.Is(err, service.ErrNotFound):
		status, code, message = 404, "not_found", "Data tidak ditemukan."
	case errors.Is(err, service.ErrConflict):
		status, code, message = 409, "conflict", "Data sudah ada atau telah berubah. Muat ulang sebelum mencoba lagi."
	case errors.Is(err, service.ErrRateLimited):
		status, code, message = 429, "rate_limited", "Terlalu banyak percobaan. Coba lagi nanti."
		w.Header().Set("Retry-After", "900")
	case errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled):
		status, code, message = 503, "unavailable", "Layanan sedang sibuk. Coba lagi."
	}
	if status == 500 {
		a.logger.Error("data operation failed", "request_id", id)
	}
	a.fail(w, r, status, code, message, id)
}

func (a *API) decode(w http.ResponseWriter, r *http.Request, id string, target any) bool {
	media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || media != "application/json" {
		a.fail(w, r, 415, "unsupported_media_type", "Gunakan Content-Type application/json.", id)
		return false
	}
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		var large *http.MaxBytesError
		if errors.As(err, &large) {
			a.fail(w, r, 413, "body_too_large", "Body maksimal 16 KiB.", id)
		} else {
			a.fail(w, r, 400, "invalid_request", "Body tidak dapat dibaca.", id)
		}
		return false
	}
	if !utf8.Valid(body) || !uniqueObject(body) || !exactFields(body, target) {
		a.fail(w, r, 400, "invalid_request", "Gunakan satu objek JSON tanpa field duplikat.", id)
		return false
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		a.fail(w, r, 400, "invalid_request", "Format JSON atau field tidak valid.", id)
		return false
	}
	return true
}
func uniqueObject(body []byte) bool {
	d := json.NewDecoder(bytes.NewReader(body))
	token, err := d.Token()
	if err != nil || token != json.Delim('{') {
		return false
	}
	seen := map[string]bool{}
	for d.More() {
		token, err := d.Token()
		if err != nil {
			return false
		}
		key, ok := token.(string)
		if !ok || seen[key] {
			return false
		}
		seen[key] = true
		var value json.RawMessage
		if err := d.Decode(&value); err != nil {
			return false
		}
	}
	if _, err = d.Token(); err != nil {
		return false
	}
	var extra any
	return d.Decode(&extra) == io.EOF
}

// encoding/json otherwise accepts case-insensitive aliases for field names.
func exactFields(body []byte, target any) bool {
	var fields map[string]json.RawMessage
	if json.Unmarshal(body, &fields) != nil {
		return false
	}
	typ := reflect.TypeOf(target).Elem()
	known := map[string]bool{}
	for i := 0; i < typ.NumField(); i++ {
		name := strings.Split(typ.Field(i).Tag.Get("json"), ",")[0]
		if name != "" && name != "-" {
			known[name] = true
		}
	}
	for name := range fields {
		if !known[name] {
			return false
		}
	}
	return true
}
func listOptions(r *http.Request, transaction bool) (service.ListOptions, error) {
	o := service.ListOptions{Limit: 50}
	q, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		return o, service.ErrInvalid
	}
	for key, values := range q {
		if len(values) != 1 {
			return o, service.ErrInvalid
		}
		value := values[0]
		switch key {
		case "limit":
			n, e := strconv.Atoi(value)
			if e != nil || n < 1 || n > 100 {
				return o, service.ErrInvalid
			}
			o.Limit = n
		case "offset":
			n, e := strconv.Atoi(value)
			if e != nil || n < 0 || n > 10000 {
				return o, service.ErrInvalid
			}
			o.Offset = n
		case "from", "to":
			if !transaction || !service.ValidDate(value) {
				return o, service.ErrInvalid
			}
			if key == "from" {
				o.From = value
			} else {
				o.To = value
			}
		case "type":
			if !transaction || (value != "income" && value != "expense") {
				return o, service.ErrInvalid
			}
			o.Type = value
		default:
			return o, service.ErrInvalid
		}
	}
	if o.From != "" && o.To != "" && o.From >= o.To {
		return o, service.ErrInvalid
	}
	return o, nil
}
func writeList[T any](a *API, w http.ResponseWriter, r *http.Request, values []T, o service.ListOptions) {
	more := len(values) > o.Limit
	if more {
		values = values[:o.Limit]
	}
	a.json(w, r, 200, struct {
		Items   []T  `json:"items"`
		Limit   int  `json:"limit"`
		Offset  int  `json:"offset"`
		HasMore bool `json:"has_more"`
	}{values, o.Limit, o.Offset, more})
}
