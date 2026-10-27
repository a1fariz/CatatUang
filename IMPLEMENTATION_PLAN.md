# Penuntasan Catat Uang

Setiap tahap ditutup dengan pemeriksaan yang sesuai, dokumentasi hasil, commit terpisah, dan push. Tidak ada pemasangan pada aplikasi pengguna atau perubahan database keuangan pengguna untuk pengujian.

1. **Backup eksternal terenkripsi** — ekspor seluruh data lokal tanpa secure token, pemilihan file native, validasi/dekripsi, preview, dan restore atomik ke ledger kosong. Status: implementasi dan pengujian otomatis selesai; dialog native menunggu perangkat tes.
2. **Sinkronisasi tagihan dan pembayaran** — UUID tetap, antrean offline, idempotensi pembayaran per kejadian, feed/perangkat kedua, konflik, dan rekonsiliasi pengingat. Status: selesai dan diuji dengan dua SQLite terhadap API nyata.
3. **Verifikasi email dan lupa kata sandi** — token sekali pakai/kedaluwarsa yang di-hash, rate limit, mail outbox/SMTP, tampilan Flutter, dan pengujian pengiriman lokal. Status: selesai dan diuji lokal. Provider production belum dikonfigurasi.
4. **Kesiapan production** — HTTPS/reverse proxy, role database terpisah, secret environment, backup/restore server, monitoring/readiness, serta uji beban dan runbook. Status: konfigurasi/pengujian lokal dan Backend CI selesai. Publikasi nyata memerlukan target hosting/domain.
5. **Verifikasi native dan penutupan** — CI, APK final/signature, pengujian dua perangkat khusus/offline/notifikasi/restart/restore, dan daftar keterbatasan yang belum dibuktikan. Status: tahap lokal selesai pada kode `57f956c`: Backend dan seluruh Mobile CI lulus, termasuk kedua suite native emulator. Perbaikan penantian akun/keyboard dan guard adb juga lulus pada `aa83984` serta run final. Bukti di VERIFICATION.md. Android/iOS nyata memerlukan target tes yang tersedia; aplikasi pengguna tidak digantikan oleh integration test.

**Penutupan 27 Oktober 2026:** SMTP round trip, ambang monitoring email, pemeriksaan umur/checksum backup, serta pratinjau/laporan cleanup telah selesai dan diuji. Tidak ada perubahan kode atau job verifikasi yang ditinggalkan menunggu pada penutupan. [Penerimaan akhir](RELEASE_READINESS.md) mencatat kebutuhan hosting/domain, provider email, signing, jadwal operasional target, dan perangkat nyata sebelum rilis publik. Catatan tahap di bawah adalah riwayat progres, bukan pekerjaan lokal yang masih tertunda.

Baseline: commit `483ce28`, workflow Backend dan Mobile berhasil. Pengguna mengonfirmasi belum ada hosting, domain, layanan email, atau perangkat khusus tes; kerjakan konfigurasi dan pengujian lokal dahulu. Tidak ada kredensial yang dimasukkan ke repositori.

## Bukti tahap 1

Analisis Flutter bersih. Suite menghasilkan 114 tes lulus, satu tes backend dilewati tanpa server, dan satu regresi navigasi yang kemudian diperbaiki serta lulus pada pengujian terarah. Tes backup mencakup salah frasa, ciphertext rusak, pemulihan dua database file beserta pembayaran dan antrean inflight, serta penolakan target berisi. Build Android dan pengujian dialog native dicatat terpisah; tidak ada instalasi ke aplikasi pengguna.

Build APK debug dengan plugin pemilih file berhasil. Hosting/email/perangkat bukan penghalang untuk pengujian lokal tahap berikutnya.

## Tahap 2: protokol server

Migration 6 dan endpoint agregat tagihan selesai. Semua tes backend dengan race detector dan PostgreSQL 18 lulus; OpenAPI 0.7.0 valid. Implementasi antrean/UI Flutter sedang dikerjakan sebagai progres terpisah sebelum tahap ini dinyatakan lengkap.

Flutter tahap 2 selesai: antrean/UUID/payment history, persetujuan terpisah, konflik, recovery dataset dengan cadangan, rekonsiliasi pengingat, zona waktu asal, backup v2 kompatibel v1. Enam tes baru dan dua integrasi Go nyata lulus; analyzer bersih dan APK berhasil. Rincian hasil serta keterbatasan di mobile/docs/bill-sync.md. Tahap 3 sedang dikerjakan dengan SMTP lokal sesuai pilihan pengguna.

## Tahap 3: server email akun

Migration 7, endpoint verifikasi/reset, hash token sekali pakai, revokasi sesi, encrypted mail outbox, worker lease/retry dan STARTTLS selesai. Seluruh tes backend PostgreSQL/race serta SMTP loopback lulus. OpenAPI 0.8.0 valid. UI Flutter dan pengujian regresinya sedang diselesaikan; belum ada pengiriman lewat provider nyata.

UI verifikasi/lupa password selesai dan tes kontrak/form/sesi lulus; metadata status email diperbarui tanpa mengubah token/timer. Tahap 3 siap dipakai dengan SMTP yang dikonfigurasi. Tahap 4 menyiapkan konfigurasi production dan pemeriksaan operasional lokal; publikasi nyata tetap menunggu hosting/domain.

## Tahap 4: operasional lokal

Konfigurasi Caddy/Compose production, trust proxy /32, grant runtime/mail terbatas, backup custom+checksum, restore-check clone, ops-status, loadcheck, dan runbook ditambahkan. Tes role dan restore fixture berisi transaksi/tagihan/pembayaran lulus, tanpa merestore ke source. Caddyfile/Compose valid secara lokal. Docker daemon lokal belum aktif; smoke container masuk CI. Hasil load/regresi dan final CI dicatat pada penutupan.

Load readiness lokal: 100 request, concurrency 4, 0 gagal, p95 6,147 ms (bukan SLA production). ops-status schema ready, antrean kosong. Dua integrasi ledger transaksi/tagihan Go/PostgreSQL lulus lagi dengan skema 7. Image Caddy 2.11.7-alpine terverifikasi tersedia. Tahap 4 selesai untuk konfigurasi/pengujian lokal; deploy/TLS publik menunggu domain/hosting.

## Tahap 5: validasi akhir

124 tes Flutter lulus, dua integrasi API nyata lulus, analyzer bersih. APK final paket reguler/signature lama diverifikasi serta cocok dengan 32 source Dart. Guard release menolak keystore yang belum disediakan. Native test terisolasi SQLite/backup/notifikasi serta akun ditambahkan ke emulator CI disposable; hasil eksekusi belum diasumsikan. CI terdahulu menemukan satu file belum diformat dan pemeriksaan container setelah cleanup; keduanya dibetulkan dalam commit terpisah. Detail signing/perangkat tersisa: mobile/docs/native-verification.md.

Review akhir: migration 8 memastikan snapshot tagihan atomik beserta history, ordinary payment dibatasi 2000 history, feed satu agregat/halaman dan review maksimal 8 MiB. Kalender edit/tampilan dan hitungan keterlambatan memakai zona asal termasuk DST. Seluruh backend race/PostgreSQL/restore-check lulus dengan skema 8; analyzer dan 18 tes Flutter terkait lulus. CI Backend/Mobile untuk perbaikan sebelumnya (`6f4155b`) keduanya hijau. Konfigurasi/eksekusi native CI dituntaskan pada progres berikutnya.

Hasil native terbaru: emulator berhasil boot setelah hasil kompilasi/NDK runner dibersihkan. Suite akun/Keystore/API serta SQLite/backup/notifikasi masing-masing menghasilkan All tests passed. Post-check yang mengharuskan paket integration tetap terpasang setelah flutter drive dihapus karena driver membersihkannya; pemeriksaan bahwa paket reguler tetap tidak ada dipertahankan. Bukti run dan status ulang: [VERIFICATION.md](VERIFICATION.md).
