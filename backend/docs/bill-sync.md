# Sinkronisasi agregat tagihan

`GET /v1/sync/bills?after=0&limit=50`, `GET /v1/sync/bills/{id}`, dan `POST /v1/sync/bills` memakai bearer serta `X-Sync-Dataset` yang sama dengan transaksi. Cursor tagihan terpisah. Migration 6 membuat feed snapshot immutable, clock per akun yang terkunci sampai commit, dan receipt operasi. CRUD tagihan serta pembayaran biasa ikut masuk feed. Klien harus menerapkan halaman dan cursor secara atomik.

POST menggunakan `operation_id`, UUID tagihan `id`, `base_version`, `deleted`, dan `payload`. Payload memuat BillInput, status, paid_at, serta seluruh payments dengan UUID tetap. Pembayaran yang sudah di server wajib tetap identik. ID pembayaran dan kejadian due_at tidak boleh ganda. Penghapusan mempertahankan riwayat server. Payload maksimum 512 KiB/2000 pembayaran; endpoint lain tetap 16 KiB. Saat mencapai batas, jangan menghapus riwayat untuk memaksa sinkronisasi.

Retry operasi identik mengembalikan snapshot hasil pertama, walau versi sekarang lebih baru. Versi agregat dapat naik lebih dari satu saat mengimpor pembayaran; jangan mengasumsikan base_version+1. Konflik membutuhkan review eksplisit. Dataset baru menolak receipt lama juga. Jangan mereset cursor setelah restore server tanpa rekonsiliasi.

Waktu jatuh tempo harus detik utuh, sedangkan paid_at mempertahankan mikrodetik PostgreSQL. Validasi tanggal 2000–2100 dan zona IANA tetap berlaku. Pembayaran adalah pencatatan keuangan pengguna, bukan pemindahan uang. Penulis pembayaran di service wajib memperbarui bill dalam transaksi yang sama setelah memasukkan history supaya snapshot akhir memuat pembayaran.

Validasi lokal: seluruh `go test -race -count=1 ./...` lulus menggunakan PostgreSQL 18 terisolasi. Skenario mencakup ordinary pay masuk feed, receipt lama, pembayaran offline dan retry, duplikat kejadian, upaya penghapusan history, isolasi akun, pagination/tombstone, cursor di depan, dan pergantian dataset. OpenAPI 0.7.0 valid dengan 7 warning yang sudah ada.

Hardening berikutnya: migration 8 menerbitkan satu snapshot lengkap per versi tagihan pada commit melalui deferred trigger, sehingga impor tagihan berstatus paid tidak menerbitkan event awal tanpa history. Migrasi 6/7 tidak diubah. Feed mengembalikan maksimum satu agregat per halaman walau limit lebih besar diminta; klien wajib mengikuti has_more. Batas 2000 pembayaran juga diterapkan pada ordinary PayBill, sesudah pemeriksaan replay. Tes khusus snapshot atomik/batas history dan seluruh suite race/PostgreSQL lulus. Kontrak terkini OpenAPI 0.8.0.
