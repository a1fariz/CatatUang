package httpapi

import (
	"catatuang/backend/internal/service"
	"context"
	"strings"
	"testing"
)

func TestSyncDatasetRejectsOldGenerationBeforeReceiptReplay(t *testing.T) {
	c := integrationClient(t)
	token := c.register("restore@example.com").AccessToken
	c.request("GET", "/v1/sync/state", "", nil, nil, 401)
	state := decodeResponse[struct {
		DatasetID string `json:"dataset_id"`
	}](t, c.request("GET", "/v1/sync/state", token, nil, nil, 200))
	if !service.ValidID(state.DatasetID) {
		t.Fatal("invalid dataset identity")
	}
	c.request("GET", "/v1/sync/transactions", token, nil, map[string]string{"X-Sync-Dataset": ""}, 428)
	c.request("GET", "/v1/sync/transactions", token, nil, map[string]string{"X-Sync-Dataset": "invalid"}, 422)
	p := syncInput()
	in := service.SyncMutation{OperationID: service.NewID(), ID: service.NewID(), Payload: &p}
	c.push(token, in, 200)
	page := c.pull(token, 0, 50)
	replacement := service.NewID()
	if _, err := c.pool.Exec(context.Background(), `UPDATE sync_dataset SET dataset_id=$1 WHERE id=1`, replacement); err != nil {
		t.Fatal(err)
	}
	stale := map[string]string{"X-Sync-Dataset": state.DatasetID}
	r := c.request("POST", "/v1/sync/transactions", token, in, stale, 409)
	if !strings.Contains(r.Body.String(), "sync_reset_required") {
		t.Fatal("missing reset code")
	}
	c.request("GET", "/v1/sync/transactions?after=1", token, nil, stale, 409)
	c.request("GET", "/v1/sync/transactions/"+in.ID, token, nil, stale, 409)
	if head := c.request("HEAD", "/v1/sync/state", token, nil, nil, 200); head.Body.Len() != 0 {
		t.Fatal("HEAD body")
	}
	newPage := c.pull(token, page.Cursor, 50)
	if newPage.Cursor != page.Cursor || len(newPage.Items) != 0 {
		t.Fatal("rotation changed finance data or cursor")
	}
	c.push(token, in, 200)
	if got := c.pull(token, 0, 50); len(got.Items) != 1 {
		t.Fatal("receipt replay duplicated data")
	}
}
