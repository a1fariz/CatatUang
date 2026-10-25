# Keputusan fondasi backend

Backend adalah modul Go terpisah dari Flutter. Fitur lokal mobile tetap berjalan tanpa server. Backend menyediakan HTTP, koneksi PostgreSQL, migrasi, autentikasi, CRUD transaksi/tagihan, pembayaran atomic, serta protokol sinkronisasi transaksi. Flutter menyediakan [sinkronisasi transaksi manual opsional](../../mobile/docs/transaction-sync.md); tagihan/pembayaran masih lokal.

## Batas komponen

- `cmd/api`: konfigurasi, koneksi, startup, signal, dan graceful shutdown.
- `cmd/migrate`: satu proses eksplisit untuk migrasi atau pemeriksaan versi skema.
- `cmd/healthcheck`: probe untuk container tanpa shell.
- `internal/config`: konfigurasi environment dan validasi tanpa mencetak connection string.
- `internal/database`: connection pool, migrasi transactional, checksum, advisory lock, dan pemeriksaan skema.
- `internal/httpapi`: routing, strict JSON, token Bearer, ETag/If-Match, pagination, request ID, log JSON, recovery, dan error publik.
- `internal/service`: hashing password, rate limit, sesi, validasi domain, query milik pengguna, serta transaksi pembayaran.
- `cmd/cleanup`: penghapusan sesi dan bucket rate limit yang kedaluwarsa.
- `migrations`: SQL yang di-embed ke binary agar tidak tergantung working directory.

HTTP menggunakan `net/http`. PostgreSQL menggunakan `pgxpool`. Dependency dipin melalui `go.mod` dan `go.sum`. Tidak ada ORM, dependency injection framework, atau package global untuk service state.

## Model data dan batas jaminan

- ID server adalah UUID, bukan ID integer SQLite. Fase sinkronisasi harus menambahkan pemetaan ID lokal ke UUID, termasuk ketika dua perangkat membuat data secara offline.
- Nominal adalah `BIGINT` dalam unit minor. API selanjutnya harus membatasi input ke rentang aman Dart/JSON dan menghindari konversi floating point.
- Tanggal transaksi memakai `DATE` agar perpindahan zona waktu tidak menggeser tanggal kalender. Jatuh tempo dan pembayaran memakai `TIMESTAMPTZ`; tagihan juga menyimpan nama zona IANA untuk pengulangan kalender.
- Mata uang disimpan per catatan untuk mempertahankan arti nominal. Aplikasi saat ini tetap hanya memakai satu mata uang aktif. Penegakan konsistensi mata uang pengguna dan kategori per jenis dilakukan pada layanan domain berikutnya.
- `user_id`, foreign key, dan indeks menyiapkan kepemilikan data. Foreign key gabungan mencegah pembayaran terhubung ke tagihan milik pengguna lain. Trigger melarang perpindahan pemilik transaksi/tagihan/pengaturan saat update.
- Pemilik diperoleh dari sesi Bearer, tidak dari body/query. Setiap query data dibatasi dengan `user_id`; akses ke ID milik akun lain menghasilkan 404. Tes integrasi menguji baca, edit, hapus, daftar, dan pembayaran lintas akun. RLS belum diterapkan; isolasi akses dilakukan pada query layanan dan foreign key.
- Pembayaran memakai row lock tagihan, unique constraint `(bill_id, due_at)`, dan UUID idempotensi sebagai ID pembayaran. Pembayaran dan tanggal berikutnya disimpan dalam satu transaksi database. Retry dengan key dan kejadian yang sama mengembalikan pembayaran tersimpan; penggunaan ulang key dengan payload berbeda ditolak.
- `version` bertambah melalui trigger; `updated_at` ditetapkan server. `deleted_at` menyediakan tombstone untuk transaksi dan tagihan. Ini adalah prasyarat sinkronisasi, bukan implementasi protokol sync. Tombstone belum memiliki kebijakan retensi/purge.
- Timestamp saja bukan cursor sinkronisasi yang menjamin urutan commit. Fase sync perlu memilih change log/cursor dan idempotency key, merancang konflik versi dan retry, serta menguji perubahan bersamaan dan pemulihan offline. Jangan membuat API sync hanya berdasarkan `updated_at > last_sync`.
- Password di-hash memakai Argon2id dengan salt acak 16 byte, memori 64 MiB, 3 iterasi, paralelisme 1, dan key 32 byte. Pekerjaan hash dibatasi dua operasi bersamaan per proses. Password minimal 15 karakter Unicode dan maksimal 128 byte UTF-8, tanpa trimming.
- Sesi menggunakan token acak 256-bit yang disimpan sebagai hash SHA-256; masa berlaku 24 jam. Logout mencabut satu token dan logout-all mencabut seluruh sesi akun. Refresh token belum tersedia.
- Rate limit login/register tersimpan di PostgreSQL agar berlaku lintas instance: 20 percobaan per IP dan email per 15 menit, termasuk percobaan sukses. Tidak ada akun seed atau password default.
- Riwayat pembayaran belum memiliki endpoint edit/delete/sync; desain perubahan riwayat perlu diputuskan sebelum sinkronisasi.

## Operasional dan keamanan

API tidak menjalankan DDL saat startup. Proses deployment menjalankan `migrate up`, kemudian API memeriksa checksum dan kelengkapan skema. Readiness memeriksa koneksi serta riwayat migrasi; liveness hanya memeriksa proses HTTP agar gangguan database tidak memicu restart berulang.

Migrasi diterapkan dalam satu transaksi dan advisory lock. Checksum yang berubah, versi asing, atau gap pada riwayat ditolak. File migrasi yang pernah diterapkan tidak diedit; perubahan berikutnya harus memakai file berurutan baru. Rollback operasional memakai perbaikan forward atau restore backup yang sudah diuji, bukan penghapusan tabel otomatis.

Default listener native adalah loopback. Compose mempublikasikan API dan database ke loopback host. Runtime container menggunakan UID non-root, filesystem read-only, tanpa Linux capabilities. Konfigurasi Compose khusus pengembangan menggunakan kredensial pemilik database; production harus memakai role migrasi dan role runtime terpisah dengan hak minimum. Runtime memerlukan `SELECT` pada `schema_migrations` untuk readiness.

Production mensyaratkan `sslmode=verify-full` untuk database. HTTPS untuk HTTP diterminasi oleh reverse proxy/load balancer yang dikelola deployment. Server tidak mempercayai forwarded headers atau request ID klien. Log tidak menyimpan body, query string, credential database, nilai panic, atau email pengguna. Stack trace internal hanya untuk debugging operasional.

Body dibatasi 16 KiB dan wajib application/json. Objek JSON harus tunggal, tanpa field asing, field duplikat, atau alias field berbeda kapitalisasi. PUT/DELETE/pay meminta versi kuat pada If-Match; konflik versi menghasilkan 409. Query daftar dibatasi limit 1–100 dan offset 0–10000; offset pagination belum merupakan cursor sinkronisasi. Native Flutter tidak memerlukan CORS dan tidak ada browser origin yang diizinkan oleh API. Deployment publik masih memerlukan verifikasi email, pemulihan akun, kebijakan trusted proxy/rate limit, serta operasional backup dan HTTPS.

## Tahap berikutnya

1. Penguatan siklus akun: verifikasi email, reset/ganti password, kebijakan sesi dan trusted proxy.
2. Integrasi pengaturan dan kebijakan multi-mata-uang. Flutter sudah memiliki UUID mapping, outbox, penautan akun/server, dan ledger satu mata uang; lihat `../../mobile/docs/transaction-sync.md`.
3. Protokol [sync transaksi backend](transaction-sync.md) sudah menyediakan cursor/change log, tombstone, konflik versi, dan receipt retry. Integrasi dua file SQLite terhadap backend nyata lulus. Lanjutkan uji perangkat native, identitas generasi dataset untuk pemulihan backup, serta protokol tagihan/pembayaran; endpoint CRUD biasa tetap bukan pengganti feed sync.
4. Deployment: secret management, HTTPS, backup/restore, metrik, alert, image digest, dan uji beban.

## Referensi implementasi keamanan

- [Argon2 resmi Go](https://pkg.go.dev/golang.org/x/crypto/argon2).
- [OWASP Password Storage](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html).
- [OWASP Session Management](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html).
