LOCK TABLE bills, bill_payments IN SHARE ROW EXCLUSIVE MODE;

CREATE TABLE bill_sync_clock (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    seq BIGINT NOT NULL CHECK (seq BETWEEN 1 AND 9007199254740991)
);
CREATE TABLE bill_changes (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    seq BIGINT NOT NULL CHECK (seq BETWEEN 1 AND 9007199254740991),
    record JSONB NOT NULL,
    PRIMARY KEY (user_id, seq)
);
CREATE TABLE bill_sync_receipts (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    operation_id UUID NOT NULL,
    request_hash BYTEA NOT NULL CHECK (octet_length(request_hash) = 32),
    response JSONB NOT NULL,
    PRIMARY KEY (user_id, operation_id)
);

CREATE FUNCTION bill_sync_record(b bills) RETURNS jsonb
LANGUAGE sql STABLE STRICT AS $$
    SELECT (to_jsonb(b) - 'user_id' - 'deleted_at') || jsonb_build_object(
        'deleted', b.deleted_at IS NOT NULL,
        'payments', COALESCE((SELECT jsonb_agg(to_jsonb(p) - 'user_id' - 'created_at' ORDER BY p.due_at,p.id)
            FROM bill_payments p WHERE p.user_id=b.user_id AND p.bill_id=b.id), '[]'::jsonb))
$$;
INSERT INTO bill_changes(user_id,seq,record)
SELECT user_id,row_number() OVER (PARTITION BY user_id ORDER BY updated_at,id),bill_sync_record(b) FROM bills b;
INSERT INTO bill_sync_clock(user_id,seq)
SELECT user_id,max(seq) FROM bill_changes GROUP BY user_id;

CREATE FUNCTION track_bill_sync() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE next_seq BIGINT;
BEGIN
    INSERT INTO bill_sync_clock(user_id,seq) VALUES(NEW.user_id,1)
    ON CONFLICT(user_id) DO UPDATE SET seq=bill_sync_clock.seq+1 RETURNING seq INTO next_seq;
    INSERT INTO bill_changes(user_id,seq,record) VALUES(NEW.user_id,next_seq,bill_sync_record(NEW));
    RETURN NEW;
END;
$$;
CREATE TRIGGER bills_sync AFTER INSERT OR UPDATE ON bills FOR EACH ROW EXECUTE FUNCTION track_bill_sync();

-- Payment writers must update the parent bill in the same transaction after
-- inserting history. Both PayBill and PushBill follow this ordering.
