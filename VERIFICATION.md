# Verifikasi penuntasan — 26 Oktober 2026

Baseline `483ce28`; kode final sebelum laporan `8c2f5c4`. Pekerjaan dilakukan per progres, masing-masing di-add, commit, dan push ke main repo privat [CatatUang](https://github.com/a1fariz/CatatUang). Tidak ada instalasi ke paket reguler pengguna, penghapusan database keuangan pengguna, deploy hosting, atau pengiriman email provider.

| Progres | Commit |
|---|---|
| Backup eksternal terenkripsi dan restore atomik | e9322e6 |
| Protokol server tagihan/payment history | 02457d3 |
| Antrean/UI tagihan offline dan recovery | 342b5ed |
| Verifikasi email/reset password dan SMTP worker | c9c2728 |
| UI verifikasi/reset akun | 1562c2e |
| HTTPS/config production, role, backup/restore, monitoring/load | 3cbcf69 |
| Perbaikan lifecycle CI dan format | 6f4155b |
| Snapshot tagihan atomik, batas history/memori, kalender zona asal | e960860 |
| Native CI terisolasi dan guard signing release | aabb1e3 |
| Zona penautan untuk form tagihan baru dan cache Gradle CI | b90b56e |
| Batas partisi emulator dan ruang disk runner sementara | 0be31cf |
| Cache dibatasi ke dependensi/wrapper | 8ac1e31 |
| Prebuild APK sebelum QEMU dan batas memori Gradle | 3c57a5f |
| Pembersihan hasil kompilasi/NDK sebelum membuat AVD | 424a610 |
| Koreksi post-check saat Flutter membersihkan paket integration | 8c2f5c4 |

| Pemeriksaan | Bukti |
|---|---|
| Go/PostgreSQL | Seluruh go test -race -count=1 ./... lulus dengan PostgreSQL 18 terisolasi dan schema 8, termasuk role terbatas, SMTP loopback, token race, serta restore-check berisi transaksi/tagihan/pembayaran |
| Flutter lokal | Suite 124 tes lulus sebelum tambahan kalender/form; 19 tes terkait lulus sesudahnya secara serial; analyzer bersih dan formatter CI tanpa perubahan |
| Dua ledger nyata | Dua tes integrasi SQLite file terhadap API Go final/schema 8 lulus; retry/conflict/payment/reopen serta pemulihan dataset transaksi diuji |
| Beban lokal | 100 request readiness, concurrency 4, 0 gagal; p95 2,81 ms pada run final lokal. Ini smoke test, bukan SLA production |
| Operasional | ops-status schema ready; antrean email kosong. Caddyfile valid dengan binary resmi/checksum SHA-512, Compose config valid, image dipin tersedia |
| Backend CI | [Run e960860](https://github.com/a1fariz/CatatUang/actions/runs/40321022158) berhasil, termasuk vet/vulnerability check/race/container/Caddy/backup-restore PostgreSQL 18 |
| Mobile CI | [Run 424a610](https://github.com/a1fariz/CatatUang/actions/runs/40347183557): Android dan dua ledger berhasil; kedua suite native juga All tests passed (akun 37 detik, storage 31 detik), tetapi job gagal pada post-check paket yang sudah dibersihkan flutter drive. Post-check dikoreksi pada 8c2f5c4; [run final](https://github.com/a1fariz/CatatUang/actions/runs/40349938798) berhasil seluruhnya: android, transaction-sync, dan native-android |
| Artefak lokal | APK debug paket reguler; signer lama dan 32/32 source Dart cocok dengan kernel |

APK: `.tools/catat-uang-final-debug.apk` (diabaikan Git), SHA-256 `7c906991b9a229afbd5658ca57301415f5a6eed18a960fc2dadd81e3705b049c`. Sertifikat SHA-256 `c0480972ebad36974db01b30175f2fd6ef0af162fe12431afee759539c24578b`. API development `http://10.0.2.2:8080`; bukan APK production dan tidak dipasang otomatis. Build integration lokal dibuktikan memakai ID `.integration`; build normal memakai `dev.catatuang.catat_uang`. APK akun x64 juga diperiksa mengandung target Dart integration test yang tepat.

Kegagalan native sebelumnya dicatat apa adanya: userdata terlalu besar untuk disk runner, kemudian QEMU hang ketika kompilasi/instalasi NDK berjalan bersamaan. Alur akhir memisahkan prebuild dari emulator dan menghentikan Gradle sebelum runtime. Run 3c57a5f kembali gagal sebelum boot karena NDK/hasil kompilasi menyisakan 2,6 GB; commit 424a610 menghapus hasil sementara setelah APK disalin dan mensyaratkan 12 GiB kosong sebelum instalasi image emulator. Satu unduhan NDK rusak memerlukan pengulangan job; cache besar juga diperkecil setelah arsip kehabisan disk. Run lama yang sudah digantikan dibatalkan. Semua perbaikan ini pada runner CI sementara, bukan workstation/perangkat pengguna.

Yang menunggu sarana eksternal: hosting/domain dan pengujian HTTPS publik, provider email/deliverability, secret serta keystore production/App Signing, pengujian SAF provider dokumen dan penerimaan notifikasi/reboot/battery saver di perangkat khusus, dua perangkat Android nyata, serta build/perangkat iOS dengan macOS/Xcode. Pengguna memilih konfigurasi dan pengujian lokal dahulu karena layanan/perangkat tersebut belum ada. Daftar ini tidak diganti dengan klaim persentase production.

Panduan: [operasional](backend/docs/operations.md), [email akun](backend/docs/account-email.md), [tagihan](mobile/docs/bill-sync.md), [backup](mobile/docs/external-backup.md), dan [native/signing](mobile/docs/native-verification.md).

## Progres lanjutan: email akun melalui SMTP loopback

Setelah baseline penuntasan di atas, ditambahkan `TestAccountRecoverySMTPRoundTrip` yang mengambil kode dari MIME hasil pengiriman SMTP sungguhan, kemudian mengonfirmasinya melalui HTTP. Pemeriksaan mencakup ACK/outbox, verifikasi akun, reset sekali pakai, pencabutan sesi lama, login baru, dan isi transaksi yang sama setelah pemulihan. Empat tes pemulihan akun/outbox/SMTP lulus dengan PostgreSQL 18 dan race detector; `go vet ./internal/httpapi` lulus. Tidak ada perubahan skema atau kode runtime. Perintah pengujian dan batas cakupan ada di [panduan email](backend/docs/account-email.md#uji-alur-email-utuh-tanpa-provider). Hasil lokal ini terpisah dari hasil workflow baru yang dipicu saat push.
