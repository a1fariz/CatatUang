# Catat Uang Backend

Backend Go + PostgreSQL dengan registrasi/login, sesi yang dapat dicabut, CRUD transaksi/tagihan, pembayaran idempotent, serta sinkronisasi [transaksi](docs/transaction-sync.md) dan [tagihan/pembayaran](docs/bill-sync.md). [Email akun/reset password](docs/account-email.md) memakai token sekali pakai dan worker SMTP. Flutter tetap dapat digunakan offline. Lihat [runbook production dan backup](docs/operations.md).

## Prasyarat

- Go 1.26 atau lebih baru; pengembangan ini diverifikasi menggunakan Go 1.27.3.
- PostgreSQL 18, atau Docker Desktop dengan Linux containers.
- Windows: `scripts/go.ps1` memakai SDK portable di `../.tools/go` jika tersedia, lalu Go dari PATH sebagai fallback. Cache Go disimpan di `../.tools` dan diabaikan Git. Jalankan wrapper dari folder `backend`.

## Jalankan dengan Docker Compose

```powershell
Copy-Item .env.example .env
```

Edit `.env`: ganti `POSTGRES_PASSWORD` dengan nilai acak hexadecimal yang panjang dan samakan password pada `DATABASE_URL`. Jangan commit `.env`. Untuk menghasilkan nilai: `[Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32))`.

```powershell
docker compose up --build -d
docker compose ps
Invoke-RestMethod http://127.0.0.1:8080/healthz
Invoke-RestMethod http://127.0.0.1:8080/readyz
Invoke-RestMethod http://127.0.0.1:8080/v1
docker compose logs api migrate
docker compose down
```

Urutan startup: PostgreSQL sehat → migrasi sukses → API. Volume database tetap disimpan saat `down`. Jangan gunakan opsi penghapusan volume kecuali memang ingin menghapus data. Compose ini untuk pengembangan lokal; lihat keputusan production di `docs/architecture.md`.

Jika hanya membutuhkan PostgreSQL dari Compose untuk menjalankan Go native:

```powershell
docker compose up -d db
$env:DATABASE_URL = 'postgres://catatuang:YOUR_HEX_PASSWORD@127.0.0.1:5433/catatuang?sslmode=disable'
./scripts/go.ps1 run ./cmd/migrate up
./scripts/go.ps1 run ./cmd/migrate status
./scripts/go.ps1 run ./cmd/api
```

Jika Go ada di PATH, gunakan `go` menggantikan `./scripts/go.ps1`. `.env` otomatis dibaca oleh Compose, bukan oleh binary Go. Untuk kredensial URL dengan karakter khusus, lakukan percent-encoding; Compose contoh mengasumsikan password hexadecimal. Perubahan password `.env` tidak mengubah password cluster PostgreSQL yang sudah ada; ubah melalui administrasi database.

## Konfigurasi

| Environment | Default | Aturan |
|---|---|---|
| `APP_ENV` | `development` | `development`, `test`, `production` |
| `HTTP_ADDR` | `127.0.0.1:8080` | Host:port, port 1–65535 |
| `DATABASE_URL` | wajib | URL PostgreSQL dengan host, user, database |
| `DB_MAX_CONNECTIONS` | `10` | 1–100 |
| `DB_TIMEOUT` | `3s` | 1s–1m untuk koneksi/query readiness |
| `SHUTDOWN_TIMEOUT` | `10s` | 1s–1m |

Production wajib menggunakan `sslmode=verify-full`. Tidak ada password atau DSN yang dicetak ke log. API memiliki batas header 16 KiB, timeout pembacaan, timeout penulisan, dan graceful shutdown. Migrasi memiliki deadline 1 menit, statement timeout 55 detik, dan lock timeout 10 detik; untuk perubahan besar, desain migrasi bertahap.

## Kontrak HTTP

| Endpoint | Berhasil | Gagal |
|---|---|---|
| `GET /healthz` | `200 {"status":"ok"}` | Tidak bergantung pada database |
| `GET /readyz` | `200 {"status":"ready"}` | `503` jika DB/skema belum siap |
| `GET /v1` | `200` informasi layanan dan tahap `authenticated-api` | — |

`HEAD` didukung tanpa body. Endpoint tidak dikenal mengembalikan `404`; metode tidak sesuai mengembalikan `405` beserta `Allow`. Respons memakai JSON, `Cache-Control: no-store`, dan `X-Request-ID` yang dibuat server.

```json
{"error":{"code":"not_ready","message":"Layanan belum siap.","request_id":"..."}}
```

Error publik tidak berisi detail driver atau koneksi. Request ID yang sama ada pada log JSON untuk pelacakan. Kontrak lengkap ada di `docs/openapi.json`; contoh penggunaan tersedia di `docs/api.md`.

| Endpoint | Perilaku |
|---|---|
| `POST /v1/auth/register`, `/v1/auth/login` | Membuat sesi Bearer selama 24 jam |
| `POST /v1/auth/logout`, `/v1/auth/logout-all` | Mencabut satu atau seluruh sesi akun |
| `GET /v1/me` | Identitas dari sesi |
| `GET`, `POST /v1/transactions` | Daftar/filter dan tambah transaksi |
| `GET`, `PUT`, `DELETE /v1/transactions/{id}` | Baca, ganti, dan soft delete |
| `GET`, `POST /v1/bills` | Daftar dan tambah tagihan |
| `GET`, `PUT`, `DELETE /v1/bills/{id}` | Baca, ganti, dan soft delete |
| `POST /v1/bills/{id}/pay` | Bayar dan majukan jatuh tempo secara atomic |
| `GET /v1/bills/{id}/payments` | Riwayat pembayaran |

Endpoint data memerlukan `Authorization: Bearer TOKEN`. PUT/DELETE/pay memerlukan `If-Match` dari ETag terakhir; pay juga memerlukan UUID pada `Idempotency-Key`. Permintaan JSON maksimal 16 KiB; field asing, field duplikat, dan alias nama field berbeda kapitalisasi ditolak.

Password di-hash menggunakan Argon2id, dengan salt acak per password. Token acak 256-bit hanya tersimpan sebagai SHA-256 di database. Login/register dibatasi 20 percobaan per 15 menit untuk masing-masing IP koneksi dan email ternormalisasi. Forwarded headers tidak dipercaya; ketika memakai reverse proxy, semua klien melalui proxy berbagi batas IP sampai kebijakan trusted proxy dirancang.

## Migrasi dan pemeriksaan

```powershell
./scripts/go.ps1 run ./cmd/migrate up
./scripts/go.ps1 run ./cmd/migrate status
./scripts/go.ps1 mod verify
./scripts/go.ps1 vet ./...
./scripts/go.ps1 test -count=1 -cover ./...
./scripts/go.ps1 build ./cmd/...
```

`up` idempotent dan transactional. API menolak startup ketika skema belum sesuai; jalankan migrasi secara eksplisit. Jangan edit SQL yang telah diterapkan karena checksum akan berbeda. Tambahkan file bernomor berikutnya. Tidak ada perintah `down` yang dapat menghapus data secara tidak sengaja.

Tes HTTP dan konfigurasi berjalan tanpa database. Tes integrasi dilewati kecuali `TEST_DATABASE_URL` diisi. Gunakan **cluster pengujian**, dengan role yang boleh membuat database:

```powershell
$env:TEST_DATABASE_URL = 'postgres://test_user:TEST_PASSWORD@127.0.0.1:55439/postgres?sslmode=disable'
./scripts/go.ps1 test -count=1 -v ./internal/database
```

Setiap tes integrasi membuat database baru bernama `catatuang_test_*` dan menghapus database tersebut setelah selesai. Tes mencakup migrasi bersamaan, rollback kegagalan migrasi, checksum, constraint nominal, versi perubahan, soft delete, kepemilikan pembayaran, dan pencegahan pembayaran ganda. Jangan arahkan konfigurasi ini ke production.

Jalankan `./scripts/go.ps1 run ./cmd/cleanup` secara berkala menggunakan environment database yang sama untuk menghapus sesi dan bucket rate limit yang kedaluwarsa. Tidak ada job yang dipasang otomatis. Contoh container: `docker compose run --rm --entrypoint /app/cleanup api`. Cleanup tidak menghapus transaksi, tagihan, atau pembayaran.

Workflow `.github/workflows/backend.yml` menjalankan format, module verification, vet, govulncheck, tes dengan race detector dan PostgreSQL, build binary, build image Docker, serta startup/readiness dan graceful shutdown container. Race detector lokal memerlukan toolchain C yang sesuai; Linux CI menyediakannya. Workflow belum dijalankan di GitHub; hasil pemeriksaan lokal dicatat di `docs/verification.md` dan `docs/api-verification.md`.

## Batas implementasi

Belum tersedia verifikasi email, reset/ganti password, refresh token, endpoint pengaturan akun, sinkronisasi Flutter, backup production, atau deployment publik. Sesi kedaluwarsa mengharuskan login ulang. API menyimpan mata uang secara eksplisit per catatan; kebijakan satu mata uang aktif harus diputuskan saat integrasi dengan pengaturan mobile. Baca `docs/architecture.md` sebelum memperluas endpoint.
