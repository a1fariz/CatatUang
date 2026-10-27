# Penerimaan akhir Catat Uang — 27 Oktober 2026

Dokumen ini membedakan hasil pengujian lokal/CI dari penerimaan deployment dan perangkat. Pengguna memilih konfigurasi dan pengujian lokal karena hosting, domain, layanan email, serta perangkat khusus belum tersedia. Tidak ada deploy publik, rilis store, pemasangan ke aplikasi reguler pengguna, atau cleanup/restore database pengguna pada penuntasan ini.

**Status akhir lokal: selesai pada kode `57f956c`.** [Backend CI](https://github.com/a1fariz/CatatUang/actions/runs/40476089593) dan [Mobile CI](https://github.com/a1fariz/CatatUang/actions/runs/40476089623) berhasil seluruh job, termasuk native Android. Tidak ada job verifikasi kode yang masih menunggu pada penutupan. Gerbang rilis publik di bawah masih memerlukan sarana eksternal.

## Bukti implementasi

| Bidang | Bukti dan batas |
|---|---|
| Backend akun dan data | PostgreSQL schema 8; autentikasi, sesi, verifikasi email/reset, transaksi/tagihan/payment history, dan sinkronisasi. Seluruh suite Backend CI menjalankan race detector, vet, pemeriksaan vulnerability, build, dan container smoke |
| Email lokal | HTTP → encrypted outbox → SMTP loopback → MIME → konfirmasi HTTP; reset/revokasi sesi dan preservasi transaksi diuji. Provider dan deliverability belum diuji |
| Flutter | SQLite versi 10, offline/outbox/recovery, backup terenkripsi, zona kalender, serta unit/widget/analyzer. Dua ledger SQLite terhadap API Go nyata diuji |
| Native Android | Emulator disposable dengan paket `.integration`; akun/Keystore dan SQLite/backup/jadwal notifikasi. Hasil workflow final harus dibaca pada laporan verifikasi; tidak menggantikan tes pengiriman alarm/perangkat nyata |
| Operasional | Caddy/Compose, database role terpisah, backup/checksum/restore clone, monitoring ambang email, pemeriksaan umur backup, serta preview/JSON cleanup. Tidak ada jadwal atau kanal monitor yang dipasang otomatis |
| Artefak | APK debug development; bukan APK production/store. Lihat rincian di bawah |

Tautan hasil workflow final dan riwayat kegagalan/perbaikannya ada di [VERIFICATION.md](VERIFICATION.md). Angka persentase bukan kriteria penerimaan; setiap tahap memerlukan bukti yang sesuai.

## Artefak lokal

- File: `.tools/catat-uang-final-debug.apk`, diabaikan Git.
- Paket: `dev.catatuang.catat_uang`.
- SHA-256: `7c906991b9a229afbd5658ca57301415f5a6eed18a960fc2dadd81e3705b049c`.
- Sertifikat SHA-256: `c0480972ebad36974db01b30175f2fd6ef0af162fe12431afee759539c24578b`.
- API development: `http://10.0.2.2:8080`.
- Pemeriksaan akhir: checksum sama dan 32/32 source `mobile/lib` cocok dengan kernel APK. Perubahan berikutnya pada tahap ini menyentuh backend, tes integration, skrip CI, dan dokumentasi; tidak mengubah source aplikasi yang dikemas.

Jangan memasang APK secara otomatis ke perangkat berisi data pengguna. Paket integration hanya untuk emulator baru/kosong yang lulus guard. Tidak ada keystore production yang dibuat dalam tahap lokal.

## Gerbang sebelum rilis publik

Semua item berikut masih memerlukan target dan bukti eksternal. Daftar ini tidak menyatakan deployment telah dilakukan.

- [ ] Hosting dan PostgreSQL dedicated tersedia; role migrator/runtime/mail terpisah diterapkan dan diuji pada target. Lihat [operasional](backend/docs/operations.md).
- [ ] Domain/DNS, HTTPS publik, sertifikat, firewall, dan trust proxy diverifikasi; build aplikasi menunjuk API HTTPS deployment yang benar.
- [ ] Provider SMTP dan secret outbox tersedia; pengiriman verifikasi/reset, STARTTLS, serta penerimaan email pada alamat tes benar-benar diuji. Lihat [email akun](backend/docs/account-email.md).
- [ ] Jadwal backup, penyimpanan privat/offsite terenkripsi, retention, dan kontrol akses ditetapkan. Jalankan `backup-check` serta `restore-check` pada salinan target; catat waktu pemulihan dan periksa sampel ledger.
- [ ] Scheduler/kanal monitor tersedia; uji alert antrean email, backup basi/rusak, readiness, disk, dan sertifikat. Periksa `cleanup -dry-run -json` sebelum menerapkan jadwal cleanup pada target yang benar.
- [ ] Keystore production/App Signing dan secret CI tersedia; build release berhasil dengan signing yang benar. Guard saat ini menolak release tanpa konfigurasi signing.
- [ ] Android khusus tes: dialog SAF/provider dokumen, transfer backup di luar data aplikasi, restore instalasi kosong, izin notifikasi, alarm saat app ditutup/reboot/battery saver, serta dua perangkat offline/konflik/retry diuji bersama pemeriksaan ledger. Lihat [native/signing](mobile/docs/native-verification.md).
- [ ] Jika iOS akan dirilis: macOS/Xcode, signing Apple, build dan perangkat iOS tersedia serta perilaku penyimpanan/notifikasi/backup diuji.

Gunakan [runbook](backend/docs/operations.md) untuk urutan migrasi, grant, startup, backup, dan latihan pemulihan. Deployment biasa tidak memerlukan rotasi dataset; restore server memerlukan prosedur maintenance, pencabutan kredensial hasil restore, dan rotasi dataset sebelum klien dibuka. Jangan memakai uninstall sebagai pemulihan data.
