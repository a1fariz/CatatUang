-- Publish one complete bill aggregate per committed version, including imported
-- payments. Immediate triggers could expose the insert before its history.
CREATE UNIQUE INDEX bill_changes_record_version ON bill_changes
    (user_id,(record->>'id'),(record->>'version'));

CREATE OR REPLACE FUNCTION track_bill_sync() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    next_seq BIGINT;
    current_bill bills;
BEGIN
    SELECT * INTO STRICT current_bill FROM bills WHERE user_id=NEW.user_id AND id=NEW.id;
    IF EXISTS(SELECT 1 FROM bill_changes WHERE user_id=NEW.user_id
        AND record->>'id'=NEW.id::text AND record->>'version'=current_bill.version::text) THEN
        RETURN NEW;
    END IF;
    INSERT INTO bill_sync_clock(user_id,seq) VALUES(NEW.user_id,1)
    ON CONFLICT(user_id) DO UPDATE SET seq=bill_sync_clock.seq+1 RETURNING seq INTO next_seq;
    INSERT INTO bill_changes(user_id,seq,record)
    VALUES(NEW.user_id,next_seq,bill_sync_record(current_bill));
    RETURN NEW;
END;
$$;
DROP TRIGGER bills_sync ON bills;
CREATE CONSTRAINT TRIGGER bills_sync AFTER INSERT OR UPDATE ON bills
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION track_bill_sync();
