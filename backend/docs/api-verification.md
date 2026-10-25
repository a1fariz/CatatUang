# Verifikasi autentikasi dan API data — 25 Oktober 2026

Catatan ini merekam tahap API sebelum integrasi mobile. Implementasi akun Flutter berikutnya dijelaskan di [panduan akun mobile](../../mobile/docs/account.md).

Tahap ini menambahkan akun/sesi, CRUD transaksi/tagihan, dan pembayaran atomic di atas fondasi sebelumnya. Flutter tidak diubah atau dihubungkan ke server. Seluruh tes database menggunakan cluster pengujian terpisah; proses API dan PostgreSQL pengujian dihentikan sesudah pemeriksaan.

## Hasil

| Pemeriksaan | Hasil |
|---|---|
| Format Go, `go vet ./...`, `go mod verify` | Lulus |
| Suite PostgreSQL dengan `go test -race -count=1 -coverpkg=./internal/... -coverprofile=coverage.out ./...` | Lulus tanpa laporan race |
| Coverage gabungan package internal | 85,8% |
| Build seluruh command Windows dan Linux amd64 tanpa CGO | Lulus |
| Binary API melalui HTTP nyata | Registrasi, identitas, transaksi, tagihan, pembayaran/retry, logout, dan cleanup lulus |
| Pemeriksaan log smoke test | Tidak memuat token sesi, password, email, atau catatan transaksi pengujian |
| OpenAPI, Redocly CLI 2.71.0 | Valid, tanpa error; tujuh warning gaya untuk lisensi yang belum ditentukan dan respons 4xx pada endpoint kesehatan/informasi publik |
| `docker compose config --quiet` | Valid |
| `govulncheck` v1.9.0 | Tidak ada kerentanan pada simbol atau package yang dipakai; lihat catatan modul di bawah |

## Cakupan perilaku

- Hash password memakai salt berbeda, password salah ditolak, serta hash malformed/parameter tak terduga ditolak.
- Registrasi email case-insensitive dan konflik email; login valid, password salah, akun tidak dikenal.
- Token wajib, token acak tidak valid ditolak, sesi kedaluwarsa ditolak, logout satu sesi, logout seluruh sesi, serta sesi akun lain tetap aktif.
- Rate limit tersimpan di PostgreSQL, berlaku setelah service instance dibuat ulang, dan tidak dapat diubah dengan forwarded header.
- JSON tunggal, batas body, media type, field asing/duplikat/alias kapitalisasi, query tidak valid, dan precondition versi.
- Tambah, baca, filter, edit, soft delete, metadata ETag, dan penolakan versi lama untuk transaksi.
- Pengguna lain tidak dapat membaca, mengubah, menghapus, mendaftar data, atau membayar tagihan pemilik.
- Tagihan sekali bayar menjadi lunas dan tidak dapat diedit lagi; pengulangan bulanan mempertahankan anchor setelah Februari.
- Unit test kalender mencakup akhir bulan, tahun kabisat, dan pengulangan mingguan melewati daylight saving pada jam lokal yang valid.
- Pembayaran/retry memakai ID yang sama, penggunaan key untuk payload berbeda ditolak, dan dua pembayaran bersamaan dengan key berbeda hanya mencatat satu pembayaran.
- Pagination lookahead/offset serta riwayat pembayaran yang tetap tersimpan setelah soft delete.
- Perintah cleanup menghapus sesi kedaluwarsa.
- Tes tambahan upgrade skema pertama ke migrasi sesi memeriksa bahwa transaksi keuangan yang sudah tersimpan tetap utuh.

## Catatan pemindaian dependency

`golang.org/x/crypto` diperlukan untuk `argon2`. Govulncheck mencatat GO-2026-5932 pada package `openpgp` dalam modul tersebut. Backend tidak mengimpor package itu; hasil pemindaian menunjukkan nol kerentanan pada package maupun simbol yang digunakan. Temuan ini tidak memiliki versi perbaikan dan tidak disembunyikan dengan ignore rule.

## Batas verifikasi dan pekerjaan berikutnya

- Docker daemon lokal tidak aktif, sehingga image/startup container belum diuji lokal. Binary Linux berhasil dibangun. CI sudah mencakup validasi kontrak, tes database/race, build/startup image, serta graceful shutdown container, tetapi belum dijalankan remote.
- Test suite memverifikasi domain dan isolasi akun, bukan beban production. Email verification, reset/ganti password, trusted proxy, backup/restore production, dan operasi publik masih perlu dikerjakan.
- Refresh token belum tersedia; token kedaluwarsa memerlukan login ulang. API tidak memiliki CORS browser atau cookie authentication.
- Mata uang masih eksplisit per catatan. Sinkronisasi, outbox, UUID mapping, idempotensi tambah transaksi/tagihan, serta penyimpanan token pada secure storage Flutter belum diimplementasikan.
- Riwayat pembayaran belum diekspos untuk tagihan yang dihapus. Pembayaran belum otomatis membuat transaksi pengeluaran.
- Kalender menggunakan zona IANA dan perilaku normalisasi `time.Date` Go; waktu lokal yang ambigu/tidak ada saat perubahan DST belum memiliki kebijakan produk tersendiri. Mobile saat ini memilih jam tagihan 09:00; perlu keputusan tambahan sebelum membuka pemilihan jam bebas lintas zona.
