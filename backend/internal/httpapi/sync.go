package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"catatuang/backend/internal/service"
)

func (a *API) transactionSync(w http.ResponseWriter, r *http.Request, id, user string, entity bool) {
	if r.URL.Path == "/v1/sync/state" {
		if r.URL.RawQuery != "" {
			a.serviceError(w, r, id, service.ErrInvalid)
			return
		}
		dataset, err := a.service.SyncDataset(r.Context())
		if err != nil {
			a.serviceError(w, r, id, err)
			return
		}
		a.json(w, r, 200, struct {
			DatasetID string `json:"dataset_id"`
		}{dataset})
		return
	}
	dataset := r.Header.Get("X-Sync-Dataset")
	if dataset == "" {
		a.fail(w, r, 428, "sync_dataset_required", "Perbarui aplikasi untuk memeriksa identitas dataset sebelum sinkronisasi.", id)
		return
	}
	if len(r.Header.Values("X-Sync-Dataset")) != 1 || !service.ValidID(dataset) {
		a.serviceError(w, r, id, service.ErrInvalid)
		return
	}
	if entity {
		if r.URL.RawQuery != "" {
			a.serviceError(w, r, id, service.ErrInvalid)
			return
		}
		parts := strings.Split(r.URL.Path, "/")
		result, err := a.service.GetSyncTransaction(r.Context(), user, parts[4], dataset)
		if err != nil {
			a.serviceError(w, r, id, err)
			return
		}
		a.json(w, r, 200, result)
		return
	}
	if r.Method == "POST" {
		if r.URL.RawQuery != "" {
			a.serviceError(w, r, id, service.ErrInvalid)
			return
		}
		// Check nested keys explicitly: encoding/json otherwise accepts duplicates
		// and case-insensitive aliases even with DisallowUnknownFields enabled.
		var wire struct {
			OperationID string          `json:"operation_id"`
			ID          string          `json:"id"`
			BaseVersion int64           `json:"base_version"`
			Deleted     bool            `json:"deleted"`
			Payload     json.RawMessage `json:"payload"`
		}
		if !a.decode(w, r, id, &wire) {
			return
		}
		in := service.SyncMutation{OperationID: wire.OperationID, ID: wire.ID, BaseVersion: wire.BaseVersion, Deleted: wire.Deleted}
		if len(wire.Payload) > 0 && !bytes.Equal(bytes.TrimSpace(wire.Payload), []byte("null")) {
			var payload service.TransactionInput
			if !uniqueObject(wire.Payload) || !exactFields(wire.Payload, &payload) || json.Unmarshal(wire.Payload, &payload) != nil {
				a.fail(w, r, 400, "invalid_request", "Payload transaksi tidak valid.", id)
				return
			}
			in.Payload = &payload
		}
		result, err := a.service.PushTransaction(r.Context(), user, in, dataset)
		if err != nil {
			a.serviceError(w, r, id, err)
			return
		}
		a.json(w, r, 200, result)
		return
	}
	after, limit, err := syncOptions(r.URL.RawQuery)
	if err != nil {
		a.serviceError(w, r, id, err)
		return
	}
	result, err := a.service.PullTransactions(r.Context(), user, after, limit, dataset)
	if err != nil {
		a.serviceError(w, r, id, err)
		return
	}
	a.json(w, r, 200, result)
}

func syncOptions(raw string) (int64, int, error) {
	after, limit := int64(0), 50
	q, err := url.ParseQuery(raw)
	if err != nil {
		return 0, 0, service.ErrInvalid
	}
	for key, values := range q {
		if len(values) != 1 {
			return 0, 0, service.ErrInvalid
		}
		n, err := strconv.ParseInt(values[0], 10, 64)
		if err != nil {
			return 0, 0, service.ErrInvalid
		}
		switch key {
		case "after":
			if n < 0 || n > service.MaxAmount {
				return 0, 0, service.ErrInvalid
			}
			after = n
		case "limit":
			if n < 1 || n > 100 {
				return 0, 0, service.ErrInvalid
			}
			limit = int(n)
		default:
			return 0, 0, service.ErrInvalid
		}
	}
	return after, limit, nil
}
