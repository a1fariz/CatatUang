package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"catatuang/backend/internal/service"
)

func syncInput() service.TransactionInput {
	return service.TransactionInput{Type: "expense", AmountMinor: 42000, CurrencyCode: "IDR", Category: "Makan", OccurredOn: "2026-10-25", Note: "Perangkat A"}
}
func (c *testClient) push(token string, in service.SyncMutation, status int) service.SyncRecord {
	w := c.request("POST", "/v1/sync/transactions", token, in, nil, status)
	if status != 200 {
		return service.SyncRecord{}
	}
	return decodeResponse[service.SyncRecord](c.t, w)
}
func (c *testClient) pull(token string, after int64, limit int) service.SyncPage {
	return decodeResponse[service.SyncPage](c.t, c.request("GET", fmt.Sprintf("/v1/sync/transactions?after=%d&limit=%d", after, limit), token, nil, nil, 200))
}

func TestTransactionSyncLifecycle(t *testing.T) {
	c := integrationClient(t)
	owner, other := c.register("sync@example.com"), c.register("other@example.com")
	c.request("GET", "/v1/sync/transactions", "", nil, nil, 401)
	p := syncInput()
	in := service.SyncMutation{OperationID: service.NewID(), ID: service.NewID(), Payload: &p}
	created := c.push(owner.AccessToken, in, 200)
	if created.ID != in.ID || created.Version != 1 || created.Deleted {
		t.Fatal("bad create", created)
	}
	first := c.pull(owner.AccessToken, 0, 1)
	if len(first.Items) != 1 || first.Cursor != 1 || first.HasMore {
		t.Fatal("bad initial feed", first)
	}
	if page := c.pull(other.AccessToken, 0, 50); len(page.Items) != 0 || page.Cursor != 0 {
		t.Fatal("cross-user feed leak")
	}
	c.request("GET", "/v1/sync/transactions/"+in.ID, other.AccessToken, nil, nil, 404)
	stolen := in
	stolen.OperationID = service.NewID()
	c.push(other.AccessToken, stolen, 409)
	independent := in
	independent.ID = service.NewID()
	c.push(other.AccessToken, independent, 200) // Operation IDs are scoped by account.
	// Normal CRUD changes must appear in the same feed.
	p.Note = "Perangkat B"
	updated := decodeResponse[service.Transaction](t, c.request("PUT", "/v1/transactions/"+in.ID, owner.AccessToken, p, map[string]string{"If-Match": `"1"`}, 200))
	original := syncInput()
	in.Payload = &original
	replay := c.push(owner.AccessToken, in, 200)
	if replay.Version != 1 || replay.Note != original.Note {
		t.Fatal("retry must return original receipt")
	}
	changed := in
	changed.Payload = &p
	c.push(owner.AccessToken, changed, 409)
	stale := service.SyncMutation{OperationID: service.NewID(), ID: in.ID, BaseVersion: 1, Payload: &p}
	c.push(owner.AccessToken, stale, 409)
	c.request("DELETE", "/v1/transactions/"+in.ID, owner.AccessToken, nil, map[string]string{"If-Match": fmt.Sprintf(`"%d"`, updated.Version)}, 204)
	tombstone := decodeResponse[service.SyncRecord](t, c.request("GET", "/v1/sync/transactions/"+in.ID, owner.AccessToken, nil, nil, 200))
	if !tombstone.Deleted || tombstone.Version != 3 {
		t.Fatal("missing tombstone", tombstone)
	}
	c.request("GET", "/v1/transactions/"+in.ID, owner.AccessToken, nil, nil, 404)
	second := c.pull(owner.AccessToken, first.Cursor, 1)
	if !second.HasMore || second.Cursor != 2 || second.Items[0].Record.Note != p.Note {
		t.Fatal("bad pagination", second)
	}
	third := c.pull(owner.AccessToken, second.Cursor, 1)
	if third.HasMore || third.Cursor != 3 || !third.Items[0].Record.Deleted {
		t.Fatal("bad deletion page", third)
	}
	restore := service.SyncMutation{OperationID: service.NewID(), ID: in.ID, BaseVersion: 3, Payload: &p}
	if v := c.push(owner.AccessToken, restore, 200); v.Deleted || v.Version != 4 {
		t.Fatal("explicit restore failed", v)
	}
	deletion := service.SyncMutation{OperationID: service.NewID(), ID: in.ID, BaseVersion: 4, Deleted: true}
	deleted := c.push(owner.AccessToken, deletion, 200)
	if replay := c.push(owner.AccessToken, deletion, 200); replay.Version != deleted.Version {
		t.Fatal("delete retry changed version")
	}
	page := c.pull(owner.AccessToken, 3, 100)
	if len(page.Items) != 2 || page.Cursor != 5 {
		t.Fatal("retries added feed entries", page)
	}
	ahead := c.request("GET", "/v1/sync/transactions?after=6", owner.AccessToken, nil, nil, 409)
	if !strings.Contains(ahead.Body.String(), "sync_reset_required") {
		t.Fatal("missing reset error")
	}
	if head := c.request("HEAD", "/v1/sync/transactions", owner.AccessToken, nil, nil, 200); head.Body.Len() != 0 {
		t.Fatal("HEAD returned a body")
	}
}

func TestTransactionSyncConcurrentRetry(t *testing.T) {
	c := integrationClient(t)
	user := c.register("retry@example.com").User.ID
	s := service.New(c.pool)
	dataset, err := s.SyncDataset(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	p := syncInput()
	in := service.SyncMutation{OperationID: service.NewID(), ID: service.NewID(), Payload: &p}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var wg sync.WaitGroup
	errs := make(chan error, 8)
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			v, err := s.PushTransaction(ctx, user, in, dataset)
			if err == nil && (v.ID != in.ID || v.Version != 1) {
				err = fmt.Errorf("inconsistent receipt")
			}
			errs <- err
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	page, err := s.PullTransactions(ctx, user, 0, 100, dataset)
	if err != nil || len(page.Items) != 1 {
		t.Fatal("duplicate mutation", page, err)
	}
	// Competing edits with different operation IDs cannot both win version 1.
	results := make(chan error, 2)
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			edit := in
			edit.OperationID = service.NewID()
			edit.BaseVersion = 1
			_, err := s.PushTransaction(ctx, user, edit, dataset)
			results <- err
		}()
	}
	wg.Wait()
	close(results)
	success, conflicts := 0, 0
	for err := range results {
		switch err {
		case nil:
			success++
		case service.ErrConflict:
			conflicts++
		default:
			t.Fatal(err)
		}
	}
	if success != 1 || conflicts != 1 {
		t.Fatal("concurrent edit lost conflict", success, conflicts)
	}
}

func TestTransactionSyncValidation(t *testing.T) {
	c := integrationClient(t)
	token := c.register("validation@example.com").AccessToken
	for _, query := range []string{"after=-1", "after=9007199254740992", "after=1&after=2", "limit=0", "limit=101", "offset=0", "after=no", "after=0;limit=1"} {
		c.request("GET", "/v1/sync/transactions?"+query, token, nil, nil, 422)
	}
	c.request("PUT", "/v1/sync/transactions", token, nil, nil, 405)
	c.request("POST", "/v1/sync/transactions?after=0", token, nil, nil, 422)
	p := syncInput()
	good := service.SyncMutation{OperationID: service.NewID(), ID: service.NewID(), Payload: &p}
	for _, change := range []func(*service.SyncMutation){
		func(v *service.SyncMutation) { v.OperationID = "invalid" }, func(v *service.SyncMutation) { v.ID = "invalid" },
		func(v *service.SyncMutation) { v.BaseVersion = -1 }, func(v *service.SyncMutation) { v.Payload = nil },
		func(v *service.SyncMutation) { v.Deleted = true }, func(v *service.SyncMutation) { v.Deleted = true; v.Payload = nil },
	} {
		bad := good
		change(&bad)
		c.push(token, bad, 422)
	}
	raw, _ := json.Marshal(good)
	for _, body := range []string{
		strings.Replace(string(raw), `"amount_minor":42000`, `"amount_minor":42000,"amount_minor":1`, 1),
		strings.Replace(string(raw), `"amount_minor":42000`, `"AMOUNT_MINOR":42000`, 1),
		strings.Replace(string(raw), `"note":"Perangkat A"`, `"note":"Perangkat A","extra":1`, 1),
	} {
		r := httptest.NewRequest("POST", "/v1/sync/transactions", strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Authorization", "Bearer "+token)
		dataset, err := service.New(c.pool).SyncDataset(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		r.Header.Set("X-Sync-Dataset", dataset)
		w := httptest.NewRecorder()
		c.handler.ServeHTTP(w, r)
		if w.Code != 400 {
			t.Fatalf("invalid nested JSON accepted: %d %s", w.Code, w.Body)
		}
	}
	if page := c.pull(token, 0, 50); len(page.Items) != 0 {
		t.Fatal("invalid input changed ledger")
	}
}

func TestTransactionSyncCommitAndRollback(t *testing.T) {
	c := integrationClient(t)
	owner := c.register("clock@example.com")
	other := c.register("independent@example.com")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	tx, err := c.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	_, err = tx.Exec(ctx, `INSERT INTO transactions(id,user_id,type,amount_minor,currency_code,category,occurred_on) VALUES($1,$2,'expense',1,'IDR','Makan','2026-10-25')`, service.NewID(), owner.User.ID)
	if err != nil {
		t.Fatal(err)
	}
	s := service.New(c.pool)
	p := syncInput()
	done := make(chan error, 1)
	go func() { _, err := s.SaveTransaction(ctx, owner.User.ID, "", 0, p); done <- err }()
	if page := c.pull(owner.AccessToken, 0, 100); page.Cursor != 0 || len(page.Items) != 0 {
		t.Fatal("uncommitted record visible")
	}
	// A different user's clock must remain writable while this transaction waits.
	c.request("POST", "/v1/transactions", other.AccessToken, p, nil, 201)
	if err = tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err = <-done; err != nil {
		t.Fatal(err)
	}
	page := c.pull(owner.AccessToken, 0, 100)
	if page.Cursor != 2 || len(page.Items) != 2 || page.Items[0].Sequence != 1 || page.Items[1].Sequence != 2 {
		t.Fatal("missing committed records", page)
	}
	tx, err = c.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	_, err = tx.Exec(ctx, `UPDATE transactions SET note='rolled back' WHERE user_id=$1`, owner.User.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err = tx.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	c.request("POST", "/v1/transactions", owner.AccessToken, p, nil, 201)
	next := c.pull(owner.AccessToken, page.Cursor, 100)
	if next.Cursor != 3 || len(next.Items) != 1 || next.Items[0].Sequence != 3 {
		t.Fatal("rollback advanced clock", next)
	}
}
