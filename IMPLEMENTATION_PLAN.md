# Penuntasan Catat Uang

Setiap tahap ditutup dengan pemeriksaan yang sesuai, dokumentasi hasil, commit terpisah, dan push. Tidak ada pemasangan pada aplikasi pengguna atau perubahan database keuangan pengguna untuk pengujian.

1. **Backup eksternal terenkripsi** — ekspor seluruh data lokal tanpa secure token, pemilihan file native, validasi/dekripsi, preview, dan restore atomik ke ledger kosong. Status: implementasi dan pengujian otomatis selesai; dialog native menunggu perangkat tes.
2. **Sinkronisasi tagihan dan pembayaran** — UUID tetap, antrean offline, idempotensi pembayaran per kejadian, feed/perangkat kedua, konflik, dan rekonsiliasi pengingat. Status: menunggu tahap 1.
3. **Verifikasi email dan lupa kata sandi** — token sekali pakai/kedaluwarsa yang di-hash, rate limit, mail outbox/SMTP, tampilan Flutter, dan pengujian pengiriman lokal. Status: menunggu tahap 2. Layanan email production perlu konfigurasi pengguna.
4. **Kesiapan production** — HTTPS/reverse proxy, role database terpisah, secret environment, backup/restore server, monitoring/readiness, serta uji beban dan runbook. Status: menunggu tahap 3. Publikasi nyata memerlukan target hosting/domain.
5. **Verifikasi native dan penutupan** — CI, APK final/signature, pengujian dua perangkat khusus/offline/notifikasi/restart/restore, dan daftar keterbatasan yang belum dibuktikan. Status: menunggu tahap 4. Android/iOS nyata memerlukan target tes yang tersedia; aplikasi pengguna tidak akan digantikan oleh integration test.

Baseline: commit `483ce28`, workflow Backend dan Mobile berhasil. Pengguna mengonfirmasi belum ada hosting, domain, layanan email, atau perangkat khusus tes; kerjakan konfigurasi dan pengujian lokal dahulu. Tidak ada kredensial yang dimasukkan ke repositori.

## Bukti tahap 1

Analisis Flutter bersih. Suite menghasilkan 114 tes lulus, satu tes backend dilewati tanpa server, dan satu regresi navigasi yang kemudian diperbaiki serta lulus pada pengujian terarah. Tes backup mencakup salah frasa, ciphertext rusak, pemulihan dua database file beserta pembayaran dan antrean inflight, serta penolakan target berisi. Build Android dan pengujian dialog native dicatat terpisah; tidak ada instalasi ke aplikasi pengguna.

Build APK debug dengan plugin pemilih file berhasil. Hosting/email/perangkat bukan penghalang untuk pengujian lokal tahap berikutnya.

## Tahap 2: protokol server

Migration 6 dan endpoint agregat tagihan selesai. Semua tes backend dengan race detector dan PostgreSQL 18 lulus; OpenAPI 0.7.0 valid. Implementasi antrean/UI Flutter sedang dikerjakan sebagai progres terpisah sebelum tahap ini dinyatakan lengkap.
