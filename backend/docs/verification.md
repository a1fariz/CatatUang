# Verifikasi fondasi backend — 25 Oktober 2026

Catatan ini merekam tahap fondasi. Hasil pengembangan akun dan API berikutnya ada di [api-verification.md](api-verification.md).

Lingkungan: Windows amd64, Go 1.27.3 portable, PostgreSQL 18.2. Cluster PostgreSQL pengujian terpisah dibuat di folder `.tools`, hanya mendengarkan loopback port 55439. Server pengujian dan proses API smoke test dihentikan setelah pemeriksaan.

## Hasil final

| Pemeriksaan | Hasil |
|---|---|
| `gofmt -l cmd internal migrations` | Bersih |
| `go vet ./...` | Lulus |
| `go mod verify` | Semua modul terverifikasi |
| `go test -race -count=1 -coverprofile=coverage.out ./...` dengan PostgreSQL aktif | Lulus, termasuk tes integrasi; tidak ada laporan race |
| Build Windows seluruh `cmd/...` | Lulus |
| Cross-build Linux amd64 dengan `CGO_ENABLED=0` | Lulus |
| `govulncheck` v1.9.0 setelah pembaruan dependensi | Tidak menemukan kerentanan |
| `docker compose config --quiet` | Valid |
| Binary API terhadap PostgreSQL nyata | Lulus, detail di bawah |

Coverage package internal: konfigurasi 87,1%, database 79,0%, HTTP 86,0%. Package entrypoint tidak memiliki unit test langsung; wiring startup dan migrasi diperiksa melalui smoke test binary. Coverage bukan bukti bahwa semua perilaku production sudah diuji.

## Cakupan tes

- Environment tidak valid, port, timeout, pool, kewajiban TLS database production, serta error konfigurasi yang tidak memuat secret.
- HTTP GET/HEAD, 404, 405, header keamanan, request ID, error envelope, recovery panic, deadline readiness, serta tidak bocornya query secret atau detail driver ke respons/log.
- Riwayat migrasi kosong, parsial, lengkap, checksum berubah, versi tidak dikenal, dan gap urutan.
- Dua proses migrasi bersamaan menerapkan SQL tepat sekali; migrasi yang gagal tidak meninggalkan metadata parsial.
- Nominal nol ditolak; versi dinaikkan server; tanggal kalender tetap; perpindahan pemilik ditolak; soft delete tetap menyimpan baris dan memperbarui versi.
- Pembayaran lintas pengguna ditolak; pembayaran ganda untuk kejadian tagihan yang sama ditolak; status lunas tanpa waktu pembayaran ditolak.

## Smoke test binary

1. API menolak startup pada database yang belum dimigrasikan.
2. `migrate up` menerapkan satu migrasi, pengulangan menerapkan nol, dan `status` melaporkan skema sesuai.
3. `/healthz`, `/readyz`, dan `/v1` mengembalikan 200; `/v1/users` mengembalikan 404.
4. Checksum metadata migrasi diubah pada database pengujian: readiness menjadi 503 sementara liveness tetap 200.
5. Setelah checksum dipulihkan, readiness kembali 200.
6. PostgreSQL dihentikan: liveness tetap 200 dan readiness menjadi 503.

## Perbaikan dari pemindaian

`govulncheck` awal menemukan GO-2026-6629 dan GO-2026-5970 melalui dependency transitif `golang.org/x/text` v0.29.0. Dependency dinaikkan ke v0.43.0, lalu pemindaian ulang bersih. `go.sum` diperbarui dan seluruh tes integrasi/race serta build diulang setelah perubahan dependency.

## Yang belum dijalankan

- Build dan startup image Docker lokal belum dijalankan karena Docker daemon tidak aktif. Konfigurasi Compose sudah divalidasi dan target binary Linux berhasil dibangun.
- Workflow GitHub Actions baru ditambahkan; belum ada eksekusi CI remote. Workflow mencakup build/startup image, probe readiness, dan graceful shutdown container.
- Graceful shutdown melalui signal belum diuji langsung pada proses Windows; penanganannya diimplementasikan pada server dan verifikasi container disiapkan di CI.
- Autentikasi, API domain, sinkronisasi mobile, uji beban, backup/restore production, serta deployment publik belum termasuk implementasi fondasi ini.
