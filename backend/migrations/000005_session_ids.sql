-- Public identifiers are not authentication credentials. Existing tokens and
-- expiry times remain unchanged when active sessions receive their identifiers.
ALTER TABLE sessions ADD COLUMN id UUID NOT NULL DEFAULT gen_random_uuid();
CREATE UNIQUE INDEX sessions_public_id ON sessions(id);
