-- Rotate this identity after restoring or replacing a server dataset, before
-- admitting clients. Cursor numbers alone cannot identify a divergent restore.
CREATE TABLE sync_dataset (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    dataset_id UUID NOT NULL,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO sync_dataset(id, dataset_id) VALUES (1, gen_random_uuid());
