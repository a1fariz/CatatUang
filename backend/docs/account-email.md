# Email akun dan pemulihan kata sandi

Migration 7 menambahkan status email, token purpose-bound, dan mail outbox. Akun lama tetap dapat login; email_verified default false dan tidak menggantikan pemeriksaan sesi. Verifikasi diminta pengguna melalui sesi aktif; registrasi tidak otomatis mengirim email.

POST `/v1/auth/email-verification/request` memerlukan bearer. POST `/v1/auth/email-verification/confirm` menerima `{token}`. POST `/v1/auth/password-reset/request` menerima `{email}` dan selalu memberi 202 generik untuk alamat terdaftar/tidak terdaftar. POST `/v1/auth/password-reset/confirm` menerima `{token,new_password}`. Kode dikirim sebagai teks untuk dimasukkan di aplikasi, bukan URL yang dapat dikonsumsi pemindai email. Konfirmasi sukses 204; kode tidak valid/kedaluwarsa/terpakai 422. Semua endpoint menolak query dan memakai rate limit bersama PostgreSQL; request dibatasi per IP serta akun, konfirmasi per IP serta hash kode.

Token acak 256 bit disimpan sebagai SHA-256, berlaku 24 jam untuk verifikasi dan 30 menit untuk reset. Request baru menggantikan kode lama. Konsumsi memakai lock akun lalu token dan memeriksa expiry setelah hashing. Reset mengganti hash Argon2id serta mencabut semua sesi dalam satu transaksi; tidak otomatis login. Penggantian password biasa juga membatalkan kode reset yang masih ada. Respons konfirmasi yang hilang tidak boleh di-retry otomatis: coba login dengan password baru.

API dan `/app/mail-worker` memerlukan MAIL_OUTBOX_KEY (32 byte random, base64 standar), SMTP_ADDR, SMTP_FROM, serta pasangan SMTP_USERNAME/PASSWORD jika provider meminta autentikasi. Simpan key di secret manager terpisah dari backup database. Tanpa konfigurasi, request email menghasilkan 503 secara konsisten. Key untuk payload email menggunakan AES-256-GCM dengan nonce random dan AAD ID job/penerima/purpose. Jangan mengganti key saat masih ada antrean tanpa rencana rotasi; pesan dengan key lama tidak dapat didekripsi.

SMTP memakai STARTTLS wajib, verifikasi hostname/CA, TLS minimum 1.2, deadline koneksi/pengiriman, dan tidak mengikuti redirect. SMTP_ALLOW_INSECURE_LOCAL=true hanya diterima untuk development/test ke IP loopback numerik tanpa credentials. Jangan gunakan pengecualian itu untuk provider atau alamat jaringan Docker. Untuk sink lokal, jalankan sink di 127.0.0.1:1025 dan API/worker secara native dengan environment process yang sama; scripts/go.ps1 run ./cmd/mail-worker menjalankan worker. Command Go tidak membaca .env otomatis.

Worker memakai lease UUID 2 menit dan SKIP LOCKED; retry eksponensial maksimum 8 percobaan. Setelah DATA diakui SMTP, job dihapus walau QUIT gagal. Kegagalan persistensi sesudah pengiriman dapat menghasilkan email duplikat dengan kode sama; konsumsi kode tetap sekali pakai. Log tidak memuat penerima, password, body, atau kode. Job gagal berhenti setelah 8 percobaan; pantau jumlah/umur antrean dan jalankan cleanup berkala untuk menghapus expiry.

Tes lokal PostgreSQL/race mencakup verifikasi, anti-enumerasi respons, reset/revokasi sesi, login password baru, kode purpose salah, penggantian/expiry/replay, dua konfirmasi bersamaan, ciphertext rusak, lease/retry/stale worker. Tes TCP SMTP lokal membuktikan pengiriman body/header dan penolakan server tanpa TLS. Seluruh backend lulus. Belum ada provider/domain/hosting pengguna; deliverability, SPF/DKIM/DMARC dan sertifikat provider belum divalidasi.

## Uji alur email utuh tanpa provider

`TestAccountRecoverySMTPRoundTrip` menghubungkan handler HTTP, PostgreSQL, encrypted outbox, operasi claim/finish worker, dan transport SMTP sungguhan ke sink loopback berport acak. Kode diambil dari body MIME yang diterima sink, bukan langsung dari database/hasil decrypt. Tes memverifikasi tujuan dan subjek email, penghapusan job setelah SMTP mengakui DATA, konfirmasi email, reset sekali pakai, pencabutan sesi lama, login password baru, serta isi transaksi yang tetap sama sesudah pemulihan.

Dari direktori `backend`, arahkan `TEST_DATABASE_URL` ke PostgreSQL khusus tes dengan izin membuat database sementara. Contoh konfigurasi ada pada bagian tes integrasi di README backend. Jangan memakai database production. Jalankan:

```powershell
./scripts/go.ps1 test -race -count=1 -v ./internal/httpapi -run '^TestAccountRecoverySMTPRoundTrip$'
```

Untuk Go di PATH, ganti wrapper dengan `go`. Tanpa `TEST_DATABASE_URL`, tes dilewati; hasil SKIP bukan bukti alur lulus. Fixture membuat database unik, menerapkan seluruh migrasi, dan hanya menghapus database buatannya sendiri saat selesai. Sink serta koneksi ditutup, dan tidak ada provider/domain/kredensial SMTP yang diperlukan. Isi email/kode/password tidak dicetak ke log tes. Tes ini otomatis ikut suite Backend CI. Ini menguji operasi worker melalui service yang sama; lifecycle proses binary `mail-worker`, TLS provider, deliverability, dan UI mobile tetap merupakan pemeriksaan terpisah.
