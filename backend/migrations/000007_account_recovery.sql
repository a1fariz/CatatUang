ALTER TABLE users ADD COLUMN email_verified BOOLEAN NOT NULL DEFAULT false;
CREATE TABLE account_tokens (
    token_hash BYTEA PRIMARY KEY CHECK(octet_length(token_hash)=32),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK(kind IN ('verify','reset')),
    expires_at TIMESTAMPTZ NOT NULL,
    UNIQUE(user_id,kind)
);
CREATE TABLE mail_outbox (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK(kind IN ('verify','reset')),
    recipient TEXT NOT NULL,
    encrypted_body BYTEA NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    available_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    lease_id UUID,
    lease_until TIMESTAMPTZ
);
CREATE INDEX mail_outbox_pending ON mail_outbox(available_at) WHERE attempts<8;
