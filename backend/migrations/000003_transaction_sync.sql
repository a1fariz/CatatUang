-- The per-user clock row stays locked until commit. A later committed change
-- cannot overtake an uncommitted sequence number (unlike a SQL sequence).
LOCK TABLE transactions IN SHARE ROW EXCLUSIVE MODE;

CREATE TABLE transaction_sync_clock (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    seq BIGINT NOT NULL CHECK (seq BETWEEN 1 AND 9007199254740991)
);
CREATE TABLE transaction_changes (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    seq BIGINT NOT NULL CHECK (seq BETWEEN 1 AND 9007199254740991),
    record JSONB NOT NULL,
    PRIMARY KEY (user_id, seq)
);
CREATE TABLE transaction_sync_receipts (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    operation_id UUID NOT NULL,
    request_hash BYTEA NOT NULL CHECK (octet_length(request_hash) = 32),
    response JSONB NOT NULL,
    PRIMARY KEY (user_id, operation_id)
);

CREATE FUNCTION transaction_sync_record(t transactions) RETURNS jsonb
LANGUAGE sql STABLE STRICT AS $$
    SELECT jsonb_build_object(
        'id', t.id, 'type', t.type, 'amount_minor', t.amount_minor,
        'currency_code', t.currency_code, 'category', t.category,
        'occurred_on', to_char(t.occurred_on, 'YYYY-MM-DD'), 'note', t.note,
        'version', t.version, 'created_at', t.created_at,
        'updated_at', t.updated_at, 'deleted', t.deleted_at IS NOT NULL)
$$;

-- Include existing soft deletions so an older device can remove them too.
INSERT INTO transaction_changes(user_id, seq, record)
SELECT user_id, row_number() OVER (PARTITION BY user_id ORDER BY updated_at, id),
       transaction_sync_record(t) FROM transactions t;
INSERT INTO transaction_sync_clock(user_id, seq)
SELECT user_id, max(seq) FROM transaction_changes GROUP BY user_id;

CREATE FUNCTION track_transaction_sync() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE next_seq BIGINT;
BEGIN
    INSERT INTO transaction_sync_clock(user_id, seq) VALUES (NEW.user_id, 1)
    ON CONFLICT (user_id) DO UPDATE SET seq = transaction_sync_clock.seq + 1
    RETURNING seq INTO next_seq;
    INSERT INTO transaction_changes(user_id, seq, record)
    VALUES (NEW.user_id, next_seq, transaction_sync_record(NEW));
    RETURN NEW;
END;
$$;
CREATE TRIGGER transactions_sync AFTER INSERT OR UPDATE ON transactions
FOR EACH ROW EXECUTE FUNCTION track_transaction_sync();
