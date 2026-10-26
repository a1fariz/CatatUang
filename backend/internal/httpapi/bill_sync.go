package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"

	"catatuang/backend/internal/service"
)

func (a *API) billSync(w http.ResponseWriter, r *http.Request, id, user string, entity bool) {
	dataset := r.Header.Get("X-Sync-Dataset")
	if dataset == "" {
		a.fail(w, r, 428, "sync_dataset_required", "Periksa identitas dataset sebelum sinkronisasi.", id)
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
		result, err := a.service.GetSyncBill(r.Context(), user, strings.Split(r.URL.Path, "/")[4], dataset)
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
		in := service.BillSyncMutation{OperationID: wire.OperationID, ID: wire.ID, BaseVersion: wire.BaseVersion, Deleted: wire.Deleted}
		if len(wire.Payload) > 0 && !bytes.Equal(bytes.TrimSpace(wire.Payload), []byte("null")) {
			var payload service.BillSyncPayload
			if !uniqueObject(wire.Payload) || !exactFields(wire.Payload, &payload) || json.Unmarshal(wire.Payload, &payload) != nil {
				a.serviceError(w, r, id, service.ErrInvalid)
				return
			}
			// exactFields checks the outer object; inspect each nested payment.
			var nested struct {
				Payments []json.RawMessage `json:"payments"`
			}
			_ = json.Unmarshal(wire.Payload, &nested)
			for _, raw := range nested.Payments {
				var payment service.Payment
				if !uniqueObject(raw) || !exactFields(raw, &payment) {
					a.serviceError(w, r, id, service.ErrInvalid)
					return
				}
			}
			in.Payload = &payload
		}
		result, err := a.service.PushBill(r.Context(), user, in, dataset)
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
	result, err := a.service.PullBills(r.Context(), user, after, limit, dataset)
	if err != nil {
		a.serviceError(w, r, id, err)
		return
	}
	a.json(w, r, 200, result)
}
