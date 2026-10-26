-- Run as database owner AFTER migrations, only in a dedicated Catat Uang DB.
-- Create login roles separately with unique passwords via interactive \password.
-- Expected roles: catatuang_runtime and catatuang_mail. Never grant membership
-- in the migration owner role to either of them.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO catatuang_runtime,catatuang_mail;
GRANT SELECT ON schema_migrations TO catatuang_runtime,catatuang_mail;
GRANT SELECT,INSERT,UPDATE ON users,user_settings,transactions,bills,
    transaction_sync_clock,bill_sync_clock TO catatuang_runtime;
GRANT SELECT,INSERT ON bill_payments,transaction_changes,transaction_sync_receipts,
    bill_changes,bill_sync_receipts TO catatuang_runtime;
GRANT SELECT,INSERT,DELETE ON sessions,account_tokens TO catatuang_runtime;
GRANT UPDATE(expires_at) ON sessions,account_tokens TO catatuang_runtime;
GRANT SELECT,INSERT,UPDATE,DELETE ON auth_rate_limits,mail_outbox TO catatuang_runtime;
GRANT SELECT ON sync_dataset TO catatuang_runtime;
-- PostgreSQL row locking needs an UPDATE privilege. This grant permits locking
-- but does not permit changing the dataset UUID or primary key.
GRANT UPDATE(changed_at) ON sync_dataset TO catatuang_runtime;
GRANT SELECT,UPDATE,DELETE ON mail_outbox TO catatuang_mail;
REVOKE ALL ON schema_migrations FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
-- Reapply this explicit list after each migration. No broad default DML grants:
-- new administrative tables must not silently become writable by runtime.
