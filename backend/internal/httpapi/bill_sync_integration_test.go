package httpapi

import (
	"catatuang/backend/internal/service"
	"context"
	"fmt"
	"testing"
	"time"
)

func TestBillSyncLifecycle(t *testing.T) {
	c := integrationClient(t)
	owner, other := c.register("billsync@example.com"), c.register("billother@example.com")
	due := time.Date(2026, 10, 26, 1, 0, 0, 0, time.UTC)
	payload := service.BillSyncPayload{BillInput: service.BillInput{Name: "Internet", AmountMinor: 250000, CurrencyCode: "IDR", DueAt: due, Timezone: "Asia/Jakarta", Recurrence: "monthly", RecurrenceDay: 26}, Status: "active", Payments: []service.Payment{}}
	in := service.BillSyncMutation{OperationID: service.NewID(), ID: service.NewID(), Payload: &payload}
	push := func(m service.BillSyncMutation, status int) service.BillSyncRecord {
		t.Helper()
		w := c.request("POST", "/v1/sync/bills", owner.AccessToken, m, nil, status)
		if status != 200 {
			return service.BillSyncRecord{}
		}
		return decodeResponse[service.BillSyncRecord](t, w)
	}
	created := push(in, 200)
	if created.Version != 1 || created.ID != in.ID {
		t.Fatal("missing stable identity")
	}
	c.request("GET", "/v1/sync/bills", "", nil, nil, 401)
	c.request("GET", "/v1/sync/bills/"+in.ID, other.AccessToken, nil, nil, 404)
	foreign := in
	foreign.OperationID = service.NewID()
	c.request("POST", "/v1/sync/bills", other.AccessToken, foreign, nil, 409)
	empty := decodeResponse[service.BillSyncPage](t, c.request("GET", "/v1/sync/bills", other.AccessToken, nil, nil, 200))
	if len(empty.Items) != 0 {
		t.Fatal("history leak")
	}
	paid := decodeResponse[service.PaymentResult](t, c.request("POST", "/v1/bills/"+in.ID+"/pay", owner.AccessToken, map[string]any{"due_at": due}, map[string]string{"If-Match": `"1"`, "Idempotency-Key": service.NewID()}, 200))
	replay := push(in, 200)
	if replay.Version != 1 || len(replay.Payments) != 0 {
		t.Fatal("receipt changed")
	}
	current := decodeResponse[service.BillSyncRecord](t, c.request("GET", "/v1/sync/bills/"+in.ID, owner.AccessToken, nil, nil, 200))
	if current.Version != paid.Bill.Version || len(current.Payments) != 1 {
		t.Fatal("ordinary payment missing from feed")
	}
	payload.DueAt = current.DueAt
	payload.Payments = current.Payments
	edit := service.BillSyncMutation{OperationID: service.NewID(), ID: in.ID, BaseVersion: current.Version, Payload: &payload}
	payload.Name = "Internet rumah"
	updated := push(edit, 200)
	// New operation IDs cannot pay the same occurrence twice, nor remove history.
	edit.OperationID = service.NewID()
	edit.BaseVersion = updated.Version
	payload.Payments = append(payload.Payments, service.Payment{ID: service.NewID(), BillID: in.ID, DueAt: due, AmountMinor: 250000, CurrencyCode: "IDR", PaidAt: due.Add(time.Hour)})
	push(edit, 422)
	payload.Payments = []service.Payment{}
	push(edit, 409)
	payload.Payments = current.Payments
	next := service.Payment{ID: service.NewID(), BillID: in.ID, DueAt: payload.DueAt, AmountMinor: payload.AmountMinor, CurrencyCode: "IDR", PaidAt: payload.DueAt.Add(time.Hour)}
	payload.Payments = append(payload.Payments, next)
	payload.DueAt = payload.DueAt.AddDate(0, 1, 0)
	edit.OperationID = service.NewID()
	paidOffline := push(edit, 200)
	if len(paidOffline.Payments) != 2 {
		t.Fatal("offline history missing")
	}
	if again := push(edit, 200); again.Version != paidOffline.Version || len(again.Payments) != 2 {
		t.Fatal("offline retry duplicated payment")
	}
	del := service.BillSyncMutation{OperationID: service.NewID(), ID: in.ID, BaseVersion: paidOffline.Version, Deleted: true}
	tomb := push(del, 200)
	if !tomb.Deleted || len(tomb.Payments) != 2 {
		t.Fatal("deletion lost history")
	}
	cursor := int64(0)
	seen := 0
	for i := 0; i < 20; i++ {
		page := decodeResponse[service.BillSyncPage](t, c.request("GET", fmt.Sprintf("/v1/sync/bills?after=%d&limit=1", cursor), owner.AccessToken, nil, nil, 200))
		for _, item := range page.Items {
			if item.Sequence <= cursor {
				t.Fatal("unordered feed")
			}
			seen++
		}
		cursor = page.Cursor
		if !page.HasMore {
			break
		}
	}
	if seen < 5 {
		t.Fatal("missing changes")
	}
	c.request("GET", fmt.Sprintf("/v1/sync/bills?after=%d", cursor+1), owner.AccessToken, nil, nil, 409)
	oldDataset := ""
	if err := c.pool.QueryRow(context.Background(), `SELECT dataset_id::text FROM sync_dataset WHERE id=1`).Scan(&oldDataset); err != nil {
		t.Fatal(err)
	}
	if _, err := c.pool.Exec(context.Background(), `UPDATE sync_dataset SET dataset_id=$1 WHERE id=1`, service.NewID()); err != nil {
		t.Fatal(err)
	}
	c.request("POST", "/v1/sync/bills", owner.AccessToken, del, map[string]string{"X-Sync-Dataset": oldDataset}, 409)
	c.request("GET", "/v1/sync/bills", owner.AccessToken, nil, map[string]string{"X-Sync-Dataset": ""}, 428)
}

func TestBillAggregatePublishesOnlyCompletePaymentSnapshot(t *testing.T) {
	c := integrationClient(t)
	owner := c.register("atomic-bill@example.com")
	due := time.Date(2026, 10, 26, 1, 0, 0, 0, time.UTC)
	paid := due.Add(time.Hour)
	id := service.NewID()
	payload := service.BillSyncPayload{BillInput: service.BillInput{Name: "Listrik", AmountMinor: 100000, CurrencyCode: "IDR", DueAt: due, Timezone: "Etc/UTC", Recurrence: "once", RecurrenceDay: 26}, Status: "paid", PaidAt: &paid, Payments: []service.Payment{{ID: service.NewID(), BillID: id, DueAt: due, AmountMinor: 100000, CurrencyCode: "IDR", PaidAt: paid}}}
	mutation := service.BillSyncMutation{OperationID: service.NewID(), ID: id, Payload: &payload}
	result := decodeResponse[service.BillSyncRecord](t, c.request("POST", "/v1/sync/bills", owner.AccessToken, mutation, nil, 200))
	page := decodeResponse[service.BillSyncPage](t, c.request("GET", "/v1/sync/bills?limit=100", owner.AccessToken, nil, nil, 200))
	if len(page.Items) != 1 || page.HasMore || page.Cursor != 1 || page.Items[0].Record.Version != result.Version || len(page.Items[0].Record.Payments) != 1 {
		t.Fatal("feed exposed partial payment aggregate")
	}
}

func TestBillPaymentHistoryBound(t *testing.T) {
	c := integrationClient(t)
	owner := c.register("history-bound@example.com")
	ctx := context.Background()
	due := time.Date(2026, 10, 26, 1, 0, 0, 0, time.UTC)
	bill := decodeResponse[service.Bill](t, c.request("POST", "/v1/bills", owner.AccessToken, service.BillInput{Name: "Internet", AmountMinor: 1, CurrencyCode: "IDR", DueAt: due, Timezone: "Etc/UTC", Recurrence: "weekly", RecurrenceDay: 26}, nil, 201))
	if _, err := c.pool.Exec(ctx, `INSERT INTO bill_payments(id,user_id,bill_id,due_at,amount_minor,currency_code,paid_at) SELECT gen_random_uuid(),$1,$2,$3::timestamptz-make_interval(days=>i),1,'IDR',$3::timestamptz FROM generate_series(1,2000) i`, owner.User.ID, bill.ID, due); err != nil {
		t.Fatal(err)
	}
	c.request("POST", "/v1/bills/"+bill.ID+"/pay", owner.AccessToken, map[string]any{"due_at": due}, map[string]string{"If-Match": `"1"`, "Idempotency-Key": service.NewID()}, 422)
	var count int
	if err := c.pool.QueryRow(ctx, `SELECT count(*) FROM bill_payments WHERE bill_id=$1`, bill.ID).Scan(&count); err != nil || count != 2000 {
		t.Fatal("history changed at bound")
	}
}
