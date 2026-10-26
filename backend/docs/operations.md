# Menjalankan Catat Uang

Konfigurasi production disiapkan di deploy/compose.production.yaml; belum ada hosting/domain pengguna yang dideploy. Database production harus dedicated dan mendukung PostgreSQL TLS verify-full. API container berjalan non-root, filesystem read-only, tanpa capability; hanya proxy membuka port publik. Migrasi memakai owner URL tersendiri, API memakai runtime URL, worker memakai mail URL. Mail bersifat opsional.

## Provision dan deploy

1. Buat database dedicated dengan role migrasi sebagai pemilik schema/tabel. Buat login catatuang_runtime dan catatuang_mail dengan NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT; masukkan password unik melalui prompt `\password` atau secret manager provider. Jangan beri membership owner. Atur CONNECT database untuk role tersebut.
2. Build image dari commit yang ditinjau, simpan dengan tag immutable/digest di registry yang dipilih. Template tidak membuat atau mempublikasikan registry. Salin deploy/production.env.example menjadi .env yang diabaikan Git, isi URL role dengan password URL-encoded dan sslmode=verify-full. Bila provider memerlukan CA khusus, mount file read-only dan tambahkan sslrootcert sesuai path yang dapat diakses proses. Jangan gunakan sslmode=disable di production.
3. Dengan maintenance aktif, jalankan `docker compose --env-file .env -f deploy/compose.production.yaml run --rm migrate`. Terapkan deploy/roles.sql sebagai owner sesudah migrasi. Daftar grant eksplisit harus diperiksa/dijalankan lagi setiap ada tabel baru. Runtime tidak dapat DDL, mengubah migration history/dataset UUID, menghapus transaksi fisik, atau mengubah payment history; worker tidak dapat membaca password hash/ledger.
4. Periksa API_DOMAIN dan ACME_EMAIL, DNS, firewall 80/443, serta APP_SUBNET/PROXY_IP yang tidak bertabrakan jaringan host. `docker compose --env-file .env -f deploy/compose.production.yaml config --quiet` memeriksa konfigurasi tanpa mencetak secret. Jalankan `up -d api proxy`; tambahkan `--profile mail` setelah konfigurasi email lengkap. Jangan menyalakan mail-worker dengan MAIL_DATABASE_URL kosong.
5. Periksa health internal container, `/app/ops-status`, HTTPS `/v1`, sertifikat hostname, dan log status/latency sebelum membuka klien. `/healthz` dan `/readyz` ditutup proxy publik tetapi tetap tersedia di network internal. Gunakan API_BASE_URL HTTPS pada build aplikasi. Tidak ada pinning sertifikat debug atau pengecualian TLS production.

Caddy [2.11.7](https://github.com/caddyserver/caddy/releases/tag/v2.11.7) dipin dan konfigurasi mengikuti [reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy) serta [request_body](https://caddyserver.com/docs/caddyfile/directives/request_body). Tidak ada access log URL/header; log aplikasi hanya request ID, metode, status, dan durasi. Jika menambahkan CDN/proxy, tinjau rantai kepercayaan dahulu. Backend hanya menerima satu IP X-Forwarded-For dari peer dalam TRUSTED_PROXY_CIDRS. Compose mengunci trust ke IP proxy /32; forwarded header dari sumber lain atau list/duplikat diabaikan. Jangan memperluas ke semua IP. Tanpa trust, beberapa pengguna di belakang proxy berbagi bucket rate limit IP.

## Backup dan latihan pemulihan

Alat native memerlukan pg_dump/pg_restore PostgreSQL 18 dari PATH atau `-pg-bin`. Gunakan environment DATABASE_URL untuk role backup yang dapat membaca seluruh data, bukan password dalam argumen command. URL tidak dicetak. Pada Windows gunakan folder backup privat dengan ACL pengguna/operator; di Linux file dibuat mode 0600. Dump berisi data sensitif dan **belum terenkripsi oleh command ini**: gunakan volume terenkripsi dan salinan offsite terenkripsi dengan kontrol akses terpisah. Simpan MAIL_OUTBOX_KEY di secret manager terpisah dari dump.

```powershell
./scripts/go.ps1 run ./cmd/backup -out D:/backup/catatuang-unique.dump -pg-bin 'C:/Program Files/PostgreSQL/18/bin'
./scripts/go.ps1 run ./cmd/restore-check -in D:/backup/catatuang-unique.dump -pg-bin 'C:/Program Files/PostgreSQL/18/bin'
```

Backup menolak file yang sudah ada, memakai pg_dump custom tanpa owner/ACL, flush file, dan menulis manifest SHA-256 .json setelah sukses. File tanpa manifest sukses bukan backup terverifikasi. Checksum mendeteksi kerusakan, bukan pemalsuan bila penyerang dapat mengganti dump dan manifest. Salin keduanya ke penyimpanan yang dikonfigurasi organisasi; command tidak menghapus backup lama atau menerapkan retention otomatis.

restore-check memverifikasi checksum, membuat database UUID baru pada cluster target environment, restore dengan exit-on-error, menerapkan migrasi, memeriksa schema/jumlah ledger, melatih pencabutan sesi/token/email dan rotasi dataset, lalu menghapus **hanya database clone yang baru dibuat**. Command tidak menerima nama database tujuan restore dan tidak merestore ke database asal. Role latihan perlu CREATEDB pada cluster tes terisolasi. Jalankan latihan terhadap salinan backup secara terjadwal, simpan hasil JSON, ukur RPO/RTO nyata. Jumlah data saja tidak menggantikan pemeriksaan sampel ledger oleh pemilik data.

Restore production tetap tindakan operator terencana: hentikan API/worker/semua writer, ambil backup kondisi sekarang, restore ke target yang diverifikasi, migrasi, terapkan grants, lalu dalam maintenance hapus sessions/account_tokens/mail_outbox hasil restore agar token lama tidak hidup kembali atau email terkirim ulang. Rotasi dataset melalui sync-dataset rotate-after-restore **sebelum** menerima klien. Verifikasi role/schema/HTTPS/backup lalu buka layanan. Perangkat melakukan review transaksi dan tagihan masing-masing; jangan menghapus outbox lokal. Lihat restore-sync.md dan dokumen pemulihan Flutter. Deploy biasa tidak perlu merotasi dataset.

## Monitoring dan penerimaan beban

Jalankan `/app/ops-status` dengan runtime environment untuk JSON schema readiness, pool, jumlah/umur email pending, job gagal setelah 8 percobaan, serta sesi expired. Tidak ada alamat email/token/nominal ledger di output. Jadwalkan cleanup untuk expiry. Pantau readiness internal, HTTP 5xx/429/latency dari log JSON, umur antrean >5 menit, mail_failed >0, backup terakhir >24 jam, kapasitas disk/database, dan expiry sertifikat. Ambang ini titik awal operasional, bukan SLA yang sudah dijanjikan; pilih kanal notifikasi setelah tersedia. Belum ada layanan monitor eksternal yang dikonfigurasi.

`loadcheck` hanya menerima URL health numerik loopback, 10–5000 request, 1–32 concurrency, tanpa login atau mutasi:

```powershell
./scripts/go.ps1 run ./cmd/loadcheck -target http://127.0.0.1:8080/readyz -requests 100 -concurrency 4 -max-p95 500ms
```

Command menampilkan JSON p50/p95/p99/error dan exit nonzero jika error/p95 melampaui ambang. Ini smoke test lokal, bukan pembuktian throughput production. Uji beban authenticated sync, banyak akun/riwayat panjang, dan lintas jaringan pada staging terisolasi setelah hosting tersedia.

## Bukti lokal dan CI

Go vet/build lulus. Tes race/PostgreSQL mencakup runtime/mail role serta backup ledger dan restore clone; source tetap dapat login setelah latihan. Caddyfile valid memakai binary resmi yang checksum SHA-512-nya diverifikasi; Compose config valid tanpa daemon. Docker Desktop lokal tidak aktif, sehingga build/start container, validasi image proxy, dan backup smoke dalam image PostgreSQL ditambahkan ke Backend CI. TLS/domain/provider email production belum diuji karena belum tersedia. Tidak ada deploy/pengiriman email provider atau pemasangan aplikasi pengguna selama pengerjaan ini.
