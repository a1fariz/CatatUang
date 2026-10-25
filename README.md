# Catat Uang

Aplikasi pencatat keuangan pribadi yang tetap berfungsi offline.

- `mobile/`: aplikasi Flutter, SQLite, transaksi, tagihan, dan pengingat lokal. Lihat [panduan mobile](mobile/README.md).
- `backend/`: Go + PostgreSQL dengan autentikasi dan API transaksi/tagihan. Lihat [panduan backend](backend/README.md), [arsitektur](backend/docs/architecture.md), dan [kontrak HTTP](backend/docs/openapi.json).
- `PRD.md`: ruang lingkup dan kriteria penerimaan.
- `riwayat.md`: implementasi dan hasil verifikasi.
- [Pemulihan transaksi](mobile/docs/recovery.md): peninjauan data perangkat/akun setelah dataset berubah dan cadangan transaksi lokal sebelum penerapan.

Flutter menyediakan akun opsional serta [sinkronisasi transaksi manual](mobile/docs/transaction-sync.md) dengan persetujuan penautan, antrean SQLite persisten, retry idempotent, dan pilihan konflik. Tagihan/pembayaran tetap lokal. Backend menyediakan registrasi/login, pencabutan sesi, CRUD transaksi/tagihan, pembayaran idempotent, health/readiness, migrasi, dan [protokol sinkronisasi transaksi](backend/docs/transaction-sync.md). Login/logout tidak mengunggah atau memindahkan data lokal. Panduan akun: [mobile/docs/account.md](mobile/docs/account.md).
