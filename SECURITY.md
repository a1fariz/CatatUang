# Credentials and security

## Local configuration

- Copy `backend/.env.example` to `backend/.env` for local Docker Compose.
- Copy `backend/deploy/production.env.example` to a private `.env` for deployment. Pass it with Compose's `--env-file` option.
- Keep real database URLs/passwords, SMTP credentials and `MAIL_OUTBOX_KEY` in those ignored files or your deployment secret store. Commit only example files with empty values or obvious placeholders.
- Native Go commands read process environment variables; they do not load `.env` automatically. See [backend setup](backend/README.md).
- Android release signing reads `CATATUANG_KEYSTORE_PATH`, `CATATUANG_KEY_ALIAS`, `CATATUANG_STORE_PASSWORD` and `CATATUANG_KEY_PASSWORD` from the process environment. Keep the keystore outside version control. See [native verification](mobile/docs/native-verification.md).
- `mobile/signing.env.example` lists the signing variables; copy it to ignored `mobile/signing.env` and inject the values into the build process environment. Do not include that file in Flutter assets.

Do not embed backend secrets in Flutter assets, `--dart-define` values, APKs or web bundles. Build-time client configuration is inspectable. `API_BASE_URL` is a public endpoint, not a credential; user session tokens are created at runtime and handled by the app's session storage.

The passwords and tokens in automated test fixtures are synthetic values for disposable local/CI environments. They are not deployment credentials and must never be reused for a real service. Public pull-request checks do not require production secrets.

## Before pushing

`.gitignore` excludes `.env`, named files such as `production.env`, signing keys, databases and local build artifacts. Git ignore rules do not remove files already tracked or values from earlier commits.

Run Gitleaks against tracked history, with redacted output:

```sh
gitleaks git . --log-opts="--all" --redact=100
```

The credential-scan workflow repeats this check on pushes and pull requests. A passing scan checks known patterns; it does not guarantee that every possible sensitive value is detected.

`.gitleaksignore` records eight reviewed synthetic password fixtures by exact historical commit/file/rule/line fingerprint. It does not exclude whole test files or disable credential rules. New findings must be reviewed independently.

If a real credential was committed, revoke/rotate it first, remove the value, and assess the full Git history before distributing the repository. Moving it to `.env` alone is insufficient.

## Reporting a vulnerability

Report sensitive findings privately to **alfarizi.developer@gmail.com**. Do not include passwords, access tokens, personal financial records or exploit details in a public issue.
