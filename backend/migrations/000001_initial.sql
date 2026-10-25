CREATE TABLE users (
    id UUID PRIMARY KEY,
    email TEXT NOT NULL CHECK (length(email) BETWEEN 3 AND 254 AND email = lower(btrim(email))),
    password_hash TEXT NOT NULL CHECK (length(password_hash) > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT users_email_unique UNIQUE (email)
);

CREATE TABLE user_settings (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    currency_code TEXT NOT NULL DEFAULT 'IDR' CHECK (currency_code IN ('IDR','USD','EUR','SGD')),
    month_start_day SMALLINT NOT NULL DEFAULT 1 CHECK (month_start_day BETWEEN 1 AND 28),
    notifications_enabled BOOLEAN NOT NULL DEFAULT true,
    dark_mode BOOLEAN NOT NULL DEFAULT false,
    version BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE transactions (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type TEXT NOT NULL CHECK (type IN ('income','expense')),
    amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
    currency_code TEXT NOT NULL CHECK (currency_code IN ('IDR','USD','EUR','SGD')),
    category TEXT NOT NULL CHECK (length(btrim(category)) BETWEEN 1 AND 80),
    occurred_on DATE NOT NULL,
    note TEXT NOT NULL DEFAULT '' CHECK (length(note) <= 200),
    version BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);
CREATE INDEX transactions_user_period ON transactions(user_id, occurred_on DESC, id) WHERE deleted_at IS NULL;
CREATE INDEX transactions_user_changes ON transactions(user_id, updated_at, id);

CREATE TABLE bills (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
    amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
    currency_code TEXT NOT NULL CHECK (currency_code IN ('IDR','USD','EUR','SGD')),
    due_at TIMESTAMPTZ NOT NULL,
    timezone TEXT NOT NULL CHECK (length(btrim(timezone)) BETWEEN 1 AND 100),
    recurrence TEXT NOT NULL CHECK (recurrence IN ('once','weekly','monthly','yearly')),
    recurrence_day SMALLINT NOT NULL CHECK (recurrence_day BETWEEN 1 AND 31),
    reminder_minutes INTEGER CHECK (reminder_minutes >= 0),
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','paid','cancelled')),
    paid_at TIMESTAMPTZ,
    version BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,
    UNIQUE (user_id, id),
    CHECK ((status = 'paid') = (paid_at IS NOT NULL))
);
CREATE INDEX bills_user_due ON bills(user_id, due_at, id) WHERE deleted_at IS NULL AND status = 'active';
CREATE INDEX bills_user_changes ON bills(user_id, updated_at, id);

CREATE TABLE bill_payments (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    bill_id UUID NOT NULL,
    due_at TIMESTAMPTZ NOT NULL,
    amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
    currency_code TEXT NOT NULL CHECK (currency_code IN ('IDR','USD','EUR','SGD')),
    paid_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (user_id, bill_id) REFERENCES bills(user_id, id),
    UNIQUE (bill_id, due_at)
);
CREATE INDEX bill_payments_user_history ON bill_payments(user_id, paid_at DESC, id);

CREATE FUNCTION track_row_update() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.created_at = OLD.created_at;
    NEW.updated_at = clock_timestamp();
    RETURN NEW;
END;
$$;
CREATE FUNCTION track_versioned_update() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.user_id IS DISTINCT FROM OLD.user_id THEN
        RAISE EXCEPTION 'record ownership cannot change' USING ERRCODE = '23514';
    END IF;
    IF TG_TABLE_NAME IN ('transactions', 'bills') THEN
        NEW.created_at = OLD.created_at;
    END IF;
    NEW.updated_at = clock_timestamp();
    NEW.version = OLD.version + 1;
    RETURN NEW;
END;
$$;
CREATE TRIGGER users_updated BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION track_row_update();
CREATE TRIGGER settings_updated BEFORE UPDATE ON user_settings FOR EACH ROW EXECUTE FUNCTION track_versioned_update();
CREATE TRIGGER transactions_updated BEFORE UPDATE ON transactions FOR EACH ROW EXECUTE FUNCTION track_versioned_update();
CREATE TRIGGER bills_updated BEFORE UPDATE ON bills FOR EACH ROW EXECUTE FUNCTION track_versioned_update();
