# Catat Uang

Aplikasi pencatat keuangan pribadi yang tetap berfungsi offline.

- `mobile/`: aplikasi Flutter, SQLite, transaksi, tagihan, dan pengingat lokal. Lihat [panduan mobile](mobile/README.md).
- `backend/`: Go + PostgreSQL dengan autentikasi dan API transaksi/tagihan. Lihat [panduan backend](backend/README.md), [arsitektur](backend/docs/architecture.md), dan [kontrak HTTP](backend/docs/openapi.json).
- `PRD.md`: ruang lingkup dan kriteria penerimaan.
- `riwayat.md`: implementasi dan hasil verifikasi.
- [Pemulihan transaksi](mobile/docs/recovery.md): peninjauan data perangkat/akun setelah dataset berubah dan cadangan transaksi lokal sebelum penerapan.
- [Ganti kata sandi](mobile/docs/password-change.md): verifikasi sandi lama dan pencabutan sesi lain, tanpa menghapus catatan lokal.
- [Sesi masuk](mobile/docs/sessions.md): daftar login aktif dan pencabutan satu sesi lain dengan konfirmasi.

Flutter menyediakan akun opsional serta [sinkronisasi transaksi](mobile/docs/transaction-sync.md) dan [tagihan/pembayaran](mobile/docs/bill-sync.md) manual dengan persetujuan penautan terpisah, antrean SQLite persisten, retry idempotent, dan peninjauan konflik/dataset. [Backup file terenkripsi](mobile/docs/external-backup.md) menyimpan seluruh data lokal tanpa token akun. Login/logout tidak mengunggah atau memindahkan ledger lokal.

[Verifikasi email/lupa password](mobile/docs/account-recovery.md) tersedia dengan [worker SMTP](backend/docs/account-email.md) yang dikonfigurasi. [Panduan operasional](backend/docs/operations.md) mencakup HTTPS, role database terpisah, backup/restore clone, monitoring dan uji beban lokal. Hosting/domain/provider email serta perangkat tes nyata belum tersedia; status implementasi dan bukti pengujian ada di [rencana penuntasan](IMPLEMENTATION_PLAN.md).
