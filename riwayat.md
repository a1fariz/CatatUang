# Riwayat Pengerjaan

## 2026-10-27

### Pratinjau cleanup dan laporan agregat
- Tambah `cleanup -dry-run -json`: snapshot read-only/repeatable-read menghitung sesi, rate limit, token akun, dan mail outbox expired tanpa penghapusan. Eksekusi cleanup tetap atomik, melaporkan jumlah yang benar-benar dihapus setelah commit, dan mempertahankan wrapper service lama.
- Empat tes PostgreSQL/race lulus: preview tidak mengubah data, eksekusi/idempotensi/hitungan, preservasi sesi/token/email aktif dan transaksi keuangan, rollback seluruh tabel saat delete terakhir gagal, serta regresi expiry/grant runtime. Vet dan build lulus. Cluster/database fixture tes dibersihkan.
- Tambah tes opsi CLI dan panduan batas cutoff/preview/output. Tidak ada cleanup database pengguna atau pemasangan jadwal.

### Stabilitas tes akun native dan guard emulator
- Backend CI backup `0b2ca1f` berhasil. Mobile Android/dua ledger berhasil, native gagal pada finder tombol logout sesudah login; ini berbeda dari putusnya koneksi emulator pada run monitoring sebelumnya, yang akhirnya lulus setelah dijalankan ulang.
- Tes akun menutup fokus keyboard sebelum mencari tombol dan menunggu sesi aktif/tidak sibuk dengan deadline setelah submit. Tidak ada retry request autentikasi. Perbaikan finder/state perlu dikonfirmasi oleh CI emulator berikutnya.
- Enam belas tes account screen/controller lokal lulus secara serial; analyzer bersih. Sintaks Bash valid.
- Guard memeriksa emulator benar-benar online dan query paket berhasil. Lima skenario adb mock lulus, termasuk perangkat/query gagal dan penolakan paket reguler; tidak ada akses ke perangkat nyata.

### Pemeriksaan integritas dan umur backup
- Tambah command read-only `backup-check -in ... -max-age 24h`, tanpa database atau secret. Checksum valid/umur sehat menghasilkan JSON dan exit 0; stale/future menghasilkan ID alert dan exit 1; file/manifest rusak gagal tanpa snapshot sukses.
- Pembacaan manifest bersama menolak JSON tambahan, data >4 KiB, dan timestamp kosong. Command masuk image aplikasi dan smoke backup PostgreSQL pada Backend CI.
- Tes race mencakup fresh/exact boundary/stale/future/tamper/missing/empty/trailing/oversize/zero-time serta opsi tidak valid. Vet/build lulus. Latihan backup dan restore clone PostgreSQL 18 berisi transaksi/tagihan/pembayaran lulus setelah pengetatan manifest; source tetap utuh.
- Backend CI monitoring `3657107` lulus. Mobile: Android dan dua ledger lulus, akun native lulus, lalu koneksi emulator hilang saat storage. Job native dijalankan ulang; hasil ulang belum dinyatakan berhasil.

### Ambang monitoring antrean email
- CI Backend dan Mobile progres SMTP `44052d9` berhasil.
- `ops-status` mendukung `-max-mail-failed` dan `-max-mail-age`, mempertahankan field JSON sebelumnya serta menambahkan ID alert tanpa data akun. Ambang dilampaui menghasilkan JSON dan exit nonzero; pemanggilan tanpa opsi tetap informasional.
- Unit test dan tiga regresi PostgreSQL lulus dengan race detector; vet/build lulus. Binary CLI nyata juga lulus: kondisi sehat exit 0, pelanggaran dua ambang exit 1 dengan dua alert, serta default tetap exit 0. Database fixture dibersihkan dan cluster tes dihentikan.
- Tambah pengujian batas ambang/parsing opsi dan PostgreSQL untuk email overdue, future retry, exhausted/expired job, serta sesi expired. Perintah operasional dan arti umur `available_at` didokumentasikan. Tidak ada scheduler atau kanal eksternal yang dipasang.

## 2026-10-26

### Uji email akun melalui SMTP nyata lokal
- Tambah `TestAccountRecoverySMTPRoundTrip`: request HTTP → encrypted outbox PostgreSQL → claim/send/finish → sink SMTP loopback → MIME → konfirmasi HTTP. Kode diambil dari pesan yang diterima, tanpa provider atau kredensial SMTP.
- Periksa alamat/subjek, outbox kosong setelah ACK, email terverifikasi, reset sekali pakai, sesi/password lama ditolak, login password baru, dan transaksi identik setelah pemulihan.
- Empat tes pemulihan akun/outbox/SMTP lulus dengan PostgreSQL 18 dan race detector; `go vet ./internal/httpapi` lulus. Database tes serta listener dibersihkan dan cluster yang dijalankan untuk tes dihentikan.
- Dokumentasikan perintah pengujian yang dapat diulang dan batasnya; selaraskan README backend yang masih menyebut fitur email/reset/sinkronisasi belum tersedia. Tes baru ikut suite Backend CI pada push berikutnya; keberhasilan lokal tidak menyatakan workflow baru sudah selesai.

### Penuntasan pondasi backend dan mobile
- Progres di-add, commit, dan push terpisah: backup terenkripsi, server dan UI sinkronisasi tagihan/pembayaran, email verification/password reset, konfigurasi operasional, hardening snapshot/kalender, serta native CI. Daftar commit dan bukti ada di [VERIFICATION.md](VERIFICATION.md).
- Backup file memakai AES-256-GCM/PBKDF2, mengecualikan token akun, mempertahankan antrean inflight, dan restore atomik hanya ke ledger kosong. Format v2 mendukung skema tagihan baru dan tetap membaca format v1.
- PostgreSQL sampai migration 8 dan SQLite sampai versi 10. Snapshot tagihan beserta history dipublikasikan pada commit; ID operasi/payment stabil, konflik dan perubahan dataset tidak ditimpa diam-diam. Zona jatuh tempo dipertahankan saat berpindah perangkat/zona dan melewati DST.
- Verifikasi email/reset memakai kode hashed sekali pakai, expiry, rate limit, encrypted mail outbox, lease/retry dan STARTTLS; reset mencabut semua sesi. Pengiriman diuji dengan sink SMTP loopback, tanpa provider email pengguna.
- Siapkan Caddy/Compose production, grant runtime/mail terbatas, backup custom+checksum dan restore ke clone terisolasi, ops-status, loadcheck, dan runbook. Backend CI lulus termasuk container dan restore PostgreSQL 18. Load lokal final 100 request/concurrency 4 tanpa gagal; bukan SLA production.
- Suite Flutter, analyzer, dua ledger SQLite terhadap API nyata, serta tes form/kalender terkait lulus. APK debug final memakai signer yang sama dan cocok dengan 32 source Dart. Signing release kini wajib dikonfigurasi terpisah.
- Native CI memakai paket `.integration` dan emulator disposable. Dua run awal gagal sebelum tes karena userdata default membutuhkan ruang lebih besar daripada runner; partisi/RAM dibatasi dan SDK runner yang tidak dipakai dibersihkan. Emulator kemudian boot dan kedua suite native lulus; job masih gagal pada pemeriksaan paket yang sudah dibersihkan Flutter. Pemeriksaan penutup dikoreksi; workflow final 8c2f5c4 berhasil untuk android, transaction-sync, dan native-android. Bukti run dicatat di laporan.
- Pengguna memilih konfigurasi/pengujian lokal karena belum ada hosting/domain/provider email/perangkat tes khusus. Publikasi production, keystore store, pengiriman alarm nyata/reboot/SAF, dan iOS tetap memerlukan sarana tersebut. Tidak ada instalasi ke aplikasi reguler atau restore ke database keuangan pengguna pada pengerjaan ini.

### Daftar dan pencabutan sesi masuk
- Workflow Backend dan Mobile commit `63c6baf` berhasil di GitHub.
- Tambah migrasi `000005_session_ids.sql` untuk ID publik sesi yang terpisah dari kredensial. Token, hash, created_at, dan expiry sesi lama dipertahankan; migrasi lama tidak diubah.
- Tambah GET/HEAD daftar sesi aktif dengan pagination dan DELETE satu sesi lain yang dibatasi akun pemanggil. Daftar tidak memuat token, hash, IP, atau fingerprint perangkat. Sesi sendiri ditolak dari endpoint pencabutan, gunakan logout.
- Pencabutan, logout, dan logout-all memakai row lock pengguna serta validasi ulang token di transaksi. Sesi yang dicabut saat menunggu lock tidak bisa melanjutkan pencabutan sesi lain.
- Flutter menyediakan Lihat sesi masuk, penanda sesi saat ini, konfirmasi pencabutan, load more, refresh, dan penanganan 401/404 tanpa menulis ulang secure token. Daftar menggambarkan login, bukan identifikasi perangkat fisik.
- Verifikasi: seluruh tes backend dengan race detector dan tes upgrade sesi lama lulus, go vet/build lulus, OpenAPI 0.6 valid dengan 7 warning gaya. Flutter analyze bersih dan 112 unit/widget tests lulus. Skenario dua SQLite terhadap backend nyata berhasil mencabut sesi kedua sambil mempertahankan catatan/antrean lokal serta sesi pemanggil. Database/proses tes dibersihkan; aplikasi tidak dipasang ke emulator.
- APK final diverifikasi: package normal, sertifikat debug asli, dan seluruh 24 source Dart cocok dengan kernel. SHA-256 `.tools/catat-uang-sync-debug.apk`: `f4c5b22e4ef43adb9c0fc97e44bd86af4c75b5f0f97aa6858a546babd49ddce7`.

### Ganti kata sandi dan konsistensi sesi
- CI commit `b0b18d4` berhasil untuk Backend dan Mobile.
- Tambah endpoint Bearer `/v1/auth/change-password`, verifikasi sandi lama, hash Argon2id baru, serta pencabutan sesi lain dalam satu transaksi. Token aktif dan expiry semula dipertahankan; tidak ada migrasi/skema keuangan baru.
- Login memeriksa hash lagi di bawah row lock sebelum menerbitkan sesi agar verifikasi hash lama tidak lolos setelah sandi berubah. Validitas token diperiksa lagi di transaksi ganti sandi; kegagalan pencabutan sesi membatalkan hash baru.
- Tambah rate limit khusus IP/per akun, strict JSON, dan kontrak OpenAPI 0.5. Flutter menyediakan form lama/baru/konfirmasi, pembersihan isian setiap percobaan, cooldown, penanganan 401/expiry, dan hasil jaringan yang belum pasti tanpa retry POST otomatis.
- Verifikasi: go vet/build dan seluruh tes PostgreSQL dengan race detector lulus, termasuk login yang diblokir row lock saat hash diganti dan rollback pencabutan yang diinduksi gagal. OpenAPI valid dengan 7 warning gaya. Flutter analyze bersih dan 107 unit/widget tests lulus. Pengujian native/perilaku password manager dan pemulihan lupa sandi belum dilakukan.
- Skenario backend nyata lulus dengan dua sesi: sandi lama ditolak, sandi baru diterima, sesi kedua dicabut, serta snapshot transaksi dan antrean kedua SQLite tetap sama. Database/proses tes dibersihkan.
- APK final berhasil dibangun tanpa instalasi emulator; package normal, sertifikat asli, dan seluruh 23 source Dart pada kernel cocok. SHA-256 `.tools/catat-uang-sync-debug.apk`: `830a9b14d864911d868beb4cde61d82221a178bdba3ee4863c9e7d3180167aa9`.

### Peninjauan pemulihan dan cadangan transaksi lokal
- Commit `9eca750` yang sempat tertahan DNS berhasil dipush; workflow Backend dan Mobile (Android serta transaction-sync) berhasil di GitHub.
- Tambah peninjauan data perangkat/akun setelah dataset berubah atau ledger legacy belum memiliki pin. Seluruh perbedaan record yang dikenal harus dipilih; tidak ada reset antrean otomatis di balik penghentian sync.
- Terapkan pilihan, mapping, cursor, dataset, generasi lokal, antrean, serta cadangan kondisi sebelumnya secara atomik. Deteksi perubahan lokal sejak peninjauan, rotasi kedua, dan respons usang. Pilihan perangkat memakai UUID record yang tetap untuk mencegah duplikasi.
- Tambah daftar cadangan lokal dan restore transaksi/antrean sebelum pemulihan, sambil mencadangkan kondisi saat ini. Tagihan/pembayaran/pengaturan tidak diganti. Cadangan berada di SQLite yang sama, belum bisa diekspor, tidak dipangkas otomatis, dan ikut dihapus oleh hapus semua data lokal.
- SQLite versi 9 menambahkan `sync_recovery_backups`; migrasi dan operasi inflight lama dipertahankan. Tambah tes rollback dengan kegagalan tulis yang diinduksi, operasi legacy yang sudah diterima, dialog pilihan/konfirmasi, serta pengembalian cadangan.
- Verifikasi lokal: 99 unit/widget tests lulus dan analyze bersih. Skenario dua file SQLite terhadap Go/PostgreSQL nyata lulus dengan rotasi dataset serta pemulihan pilihan pada kedua perangkat. Workflow mobile diperluas untuk menjalankan skenario ini. Tidak ada instalasi aplikasi atau perubahan pada image emulator.
- APK pemulihan final dibangun dan diverifikasi: package normal, sertifikat debug asli, serta kecocokan seluruh 22 source Dart pada kernel. SHA-256 `.tools/catat-uang-sync-debug.apk`: `fdbf0b145e255ab848f572e8702990cac3f69b99af6a3d99b97bc55d0f8ca984`.

### Perlindungan dataset sinkronisasi setelah restore
- CI GitHub commit awal `d079a12` berhasil untuk Backend dan Mobile, termasuk job dua SQLite terhadap backend nyata.
- Tambah migrasi PostgreSQL `000004_sync_dataset.sql`, endpoint `/v1/sync/state`, dan header wajib `X-Sync-Dataset`. Pin lama ditolak sebelum mutasi maupun replay receipt; cursor sama tidak melewati guard. Push memegang shared row lock sampai commit.
- Tambah command administrasi `sync-dataset status|rotate-after-restore` dan binary container. Rotasi harus dijalankan operator setelah restore sebelum akses klien dibuka, bukan otomatis saat restart.
- SQLite versi 8 mempertahankan transaksi/outbox dan menambahkan pin dataset. Perubahan identitas server menghentikan sync tanpa reset cursor/antrean. Ledger lama yang sudah memiliki cursor, versi remote, atau operasi inflight tidak memin identitas baru diam-diam.
- Verifikasi: seluruh tes Go dengan race detector dan PostgreSQL terisolasi lulus; go vet/build lulus; OpenAPI valid dengan 7 warning gaya; Flutter analyze bersih dan 89 unit/widget tests lulus. Dua database SQLite terhadap backend terbaru serta command status/rotasi di database tes lulus terpisah. Database dan proses tes dibersihkan.
- Panduan pemulihan ada di `backend/docs/restore-sync.md`. UI rekonsiliasi, uji restore production, tagihan/pembayaran sync, dan uji dua perangkat native belum tersedia pada tahap ini. Tidak ada pemasangan aplikasi atau perubahan image emulator.
- APK debug guard dataset berhasil dibuat, package normal dan sertifikat asli cocok, serta seluruh 19 source Dart cocok dengan kernel APK. Salinan `.tools/catat-uang-sync-debug.apk`, SHA-256 `28b8ac8cde8e98758703769a49136b03ebdbab66b374617aec085bd9b4d191d8`.

## 2026-10-25

### Integrasi sinkronisasi transaksi Flutter
- Tambah skema SQLite versi 7 dengan penautan ledger ke satu akun/server, UUID mapping, dan outbox persisten. Perubahan transaksi dan antrean ditulis atomik; migrasi tidak menautkan atau mengunggah catatan lama otomatis.
- Sinkronisasi manual mengambil perubahan server, mengirim antrean, memproses tombstone, dan menyimpan cursor bersama halaman secara atomik. Operasi inflight mempertahankan ID/payload meskipun timeout/restart; edit baru dipertahankan saat acknowledgement operasi lama datang.
- Tambah validasi receipt, penjagaan generasi ledger setelah penghapusan lokal, pemeriksaan identitas sesi/server, serta perlindungan 401 terlambat agar sesi baru tidak terhapus.
- Pengaturan menyediakan persetujuan penautan dan pilihan konflik perangkat/akun. Mata uang ledger dikunci saat tertaut dan halaman berbeda mata uang ditolak utuh. Ganti akun tidak mengalihkan antrean. Tagihan/pembayaran tetap lokal.
- Tambah tes repository, controller, HTTP, serta widget persetujuan dan konflik. Verifikasi lokal: 84 unit/widget tests lulus, analyze bersih; skenario backend nyata lulus terpisah memakai dua file SQLite, dua sesi, binary Go terbaru, dan database PostgreSQL tes tersendiri. Database/proses tes sudah dibersihkan.
- Tambah job CI sinkronisasi dengan PostgreSQL dan backend nyata, serta panduan `mobile/docs/transaction-sync.md`. CI remote, dua perangkat Android/native, dan iOS belum diuji pada tahap ini. Tidak ada instalasi aplikasi atau perubahan pada image emulator.
- APK debug sinkronisasi berhasil dibangun dengan target `lib/main.dart` dan URL host emulator. Package normal dan sertifikat debug asli diverifikasi; 19 source Dart cocok dengan kernel APK. Salinan: `.tools/catat-uang-sync-debug.apk`, SHA-256 `71ef21093e03e0ea97860cbed7e590559b5e45a2dc8ae64cb675f6c76b7c314f`. APK belum dipasang untuk uji native.

### Protokol sinkronisasi transaksi backend
- Tambah migrasi `000003_transaction_sync.sql`: clock berurutan per akun, snapshot perubahan termasuk tombstone, baseline transaksi lama, serta receipt operasi idempotent. Migrasi terdahulu tidak diubah.
- Tambah endpoint pull berbasis cursor, push satu operasi dengan UUID tetap, serta pembacaan snapshot konflik. Perubahan melalui CRUD biasa ikut masuk feed.
- Versi dasar diperiksa di bawah row lock. Retry identik mengembalikan hasil semula tanpa mutasi tambahan; ID operasi yang dipakai ulang dengan isi berbeda ditolak. Tidak ada penimpaan konflik otomatis.
- Tambah empat tes integrasi protokol yang mencakup siklus create/edit/delete/restore, dua penulis, retry paralel, isolasi akun, JSON bersarang, pagination, commit, dan rollback; perluas tes migrasi untuk baseline transaksi aktif dan terhapus.
- Verifikasi final: `go vet ./...`, `go build ./cmd/...`, dan seluruh `go test -race -count=1 ./...` lulus dengan PostgreSQL 18 lokal terisolasi. Server database tes dihentikan setelah pengujian. Generator kontrak dan pemeriksaan sintaks Node lulus; lint OpenAPI valid dengan 7 warning gaya (6 operation-4xx-response, 1 info-license).
- Flutter belum terhubung ke endpoint sync: transaksi/tagihan SQLite tetap lokal, tanpa upload saat login. Tidak ada build/instalasi Android pada tahap ini. Antrean persisten, persetujuan penautan akun, UI konflik, sinkronisasi tagihan/pembayaran, dan prosedur rekonsiliasi backup masih menjadi pekerjaan berikutnya.
- Kontrak dan batas operasional dicatat di `backend/docs/transaction-sync.md`; log/receipt belum memiliki pemangkasan dan identitas generasi dataset untuk deteksi semua skenario restore belum tersedia.

### Integrasi akun Flutter
- Tambah fitur akun opsional melalui Pengaturan: daftar/login, secure session storage, pemulihan sesi, pemeriksaan resume, expiry/401, logout satu/seluruh perangkat, serta cooldown 429.
- Tambah HTTP client dengan timeout, batas respons, pesan error lokal, dan redirect dinonaktifkan. HTTPS wajib untuk profile/release; HTTP debug dibatasi loopback/alias emulator.
- Token dipisahkan per server dan disimpan melalui flutter_secure_storage dengan verifikasi readback; password tidak disimpan pada SQLite atau preferensi aplikasi. Kegagalan storage tidak memakai fallback plaintext.
- Data keuangan tetap lokal dan tidak diunggah/dihapus saat login/logout. Sinkronisasi belum diimplementasikan.
- Perbaiki konflik Hero tag dua FAB ketika membuka route akun. Tambah aturan Android backup/transport dan entitlements Keychain iOS; cache dependency lokal dikecualikan dari analisis source.
- Verifikasi: 60 tes lulus, analyze bersih, APK biasa berhasil dibangun, seluruh 14 source Dart cocok dengan kernel APK, application ID normal, dan sertifikat cocok dengan debug keystore lama. Uji native awal satu skenario lulus terhadap backend/SQLite/secure storage nyata.
- Insiden: uji native pertama memakai Android user home berbeda sehingga debug keystore berubah. Flutter menghapus instalasi aplikasi lama dan datanya di emulator saat konflik tanda tangan. Pemulihan data lama belum terverifikasi; image setelah insiden dipertahankan.
- Tambah isolasi package integration untuk semua mode dan penanda Gradle agar target listener sementara tetap terisolasi. APK tes dengan ID `.integration` terverifikasi; percobaan berikutnya memakai salinan image/AVD khusus. Uji ulang setelah mitigasi belum selesai karena emulator tetap offline saat boot, sehingga hasil itu tidak dinyatakan lulus.
- Panduan, workflow mobile, dan laporan rinci tersedia di `mobile/docs/account.md` dan `mobile/docs/account-verification.md`. iOS native/backup/reinstall dan CI remote belum diuji.

### Autentikasi dan API transaksi/tagihan
- Tambah migrasi `000002_sessions.sql` untuk sesi dan rate limit; migrasi awal tidak diubah. Upgrade diuji agar transaksi lama tetap tersimpan.
- Tambah registrasi, login, identitas akun, logout satu/seluruh sesi, Argon2id, token Bearer acak dengan hash tersimpan, masa berlaku 24 jam, dan rate limit PostgreSQL per IP/email.
- Tambah CRUD transaksi/tagihan milik pengguna, filter periode/jenis, pagination terbatas, strict JSON 16 KiB, serta ETag/If-Match untuk mencegah penimpaan versi lama.
- Pembayaran memakai row lock dan transaksi database, UUID idempotensi, snapshot nominal/mata uang, riwayat, serta pengulangan kalender dengan anchor tanggal.
- Tambah command cleanup untuk sesi/bucket kedaluwarsa tanpa memasang scheduler, contoh penggunaan API, kontrak OpenAPI JSON beserta generator, dan langkah validasi kontrak pada CI.
- Verifikasi: suite PostgreSQL dengan race detector lulus, coverage gabungan internal 85,8%, build Windows/Linux lulus, dan smoke test binary melalui HTTP nyata lulus. Log tidak memuat secret/data pribadi pengujian.
- Govulncheck tidak menemukan kerentanan pada package/simbol yang dipakai; satu temuan modul pada OpenPGP yang tidak diimpor dicatat secara eksplisit. OpenAPI valid dengan warning gaya; Docker image dan CI remote belum dijalankan.
- Flutter tetap lokal; sinkronisasi, secure token storage mobile, serta pemulihan/verifikasi akun belum dibuat. Detail: `backend/docs/api-verification.md`.

### Fondasi backend Go + PostgreSQL
- Tambah modul `backend/` dengan HTTP bawaan Go, pgxpool, validasi environment, timeout, log JSON, request ID, recovery, dan graceful shutdown.
- Tambah `/healthz`, `/readyz`, dan `/v1`, beserta kontrak OpenAPI dan error JSON. API data serta autentikasi belum diaktifkan.
- Tambah CLI migrasi `up|status`, SQL ter-embed, transaksi, advisory lock, checksum, dan deteksi riwayat tidak sesuai. API hanya memeriksa skema dan tidak menjalankan DDL saat startup.
- Tambah skema pengguna, pengaturan, transaksi, tagihan, dan pembayaran dengan UUID, integer unit minor, foreign key kepemilikan, constraint, indeks, versi perubahan, dan tombstone. Sinkronisasi belum diimplementasikan.
- Tambah Dockerfile non-root, Compose PostgreSQL/migrasi/API, healthcheck binary, `.env.example`, wrapper Go PowerShell, workflow CI, README root/backend, arsitektur, dan laporan verifikasi.
- SDK Go portable disiapkan di `.tools/` dan diabaikan Git. Tidak ada instalasi global atau perubahan pada data Flutter.
- Verifikasi final lulus: format, vet, module verification, tes PostgreSQL dengan race detector, build Windows/Linux, dan smoke test API nyata. Pemindaian kerentanan menemukan dependency transitif yang kemudian diperbarui; hasil scan final bersih.
- Docker daemon tidak aktif: Compose valid, tetapi image belum dibangun/dijalankan lokal. Workflow CI sudah disiapkan dan belum dieksekusi remote. Detail serta batas pengujian: `backend/docs/verification.md`.

### Stabilisasi MVP lokal
- Perbaiki tanggal pengingat setelah pelunasan tagihan berulang agar memakai `recurrenceDay`, sama dengan tanggal berikutnya di SQLite.
- Pelunasan tetap mencatat pembayaran dan membatalkan pengingat lama, tetapi tidak menjadwalkan pengingat baru ketika notifikasi dimatikan.
- Tambah rekonsiliasi pengingat saat startup dan resume: baca pengaturan dan tagihan SQLite, batalkan jadwal yatim, dan pulihkan jadwal aktif tanpa meminta izin baru. Kegagalan ditampilkan dengan aksi mencoba lagi; kegagalan satu jadwal tidak menghentikan pemulihan jadwal lainnya.
- Hapus semua data kini membuat ulang layar Catatan dan Tagihan agar daftar dan ringkasan tidak mempertahankan data lama di IndexedStack.
- Tambah injeksi reminder service untuk pengujian navigasi dan pengaturan. Tes widget memakai SQLite FFI tanpa isolate agar tidak menggantung pada fake async; interaksi form menunggu animasi dan memastikan tombol terlihat.
- Tambah tes regresi pengingat akhir bulan, notifikasi nonaktif, rekonsiliasi, hapus data lintas tab, startup/resume, dan persistensi transaksi/tagihan/pengaturan setelah koneksi database file ditutup dan dibuka ulang.
- Perbarui README agar status SDK/emulator sesuai riwayat sebelumnya.

### Verifikasi
- `dart format lib test`: selesai.
- `flutter analyze --no-pub`: lulus tanpa temuan setelah perubahan terakhir.
- Suite `flutter test --no-pub --reporter expanded`: 26 tes lulus; tes tambahan startup/resume dijalankan terpisah dan lulus (total 27 kasus).
- Pengiriman notifikasi oleh Android, reboot perangkat, dan alur offline penuh belum diuji ulang pada emulator/perangkat. Tes reminder memakai fake service; tes persistensi menggunakan SQLite berbasis file pada host.

## 2026-10-04

### Setup project
- Pasang Android Studio lewat `winget`.
- Pasang Puro dan Flutter stable 3.47.6; unduhan langsung sempat gagal karena koneksi putus.
- Tambahkan Flutter SDK ke PATH user. Terminal baru perlu dibuka agar PATH termuat.
- Bootstrap aplikasi Flutter di `mobile/` dengan runner Android, iOS, web, dan Windows.
- Tambahkan dependency `sqflite`, `path`, `flutter_local_notifications`, `flutter_timezone`, `timezone`, `intl`, `sqflite_common_ffi` untuk tes, dan `flutter_lints`.
- Tulis instruksi run/check dan catatan prasyarat di `mobile/README.md`.
- Android SDK/emulator belum dipasang. Android Studio setup wizard perlu diselesaikan untuk membangun APK.
- iOS build memerlukan macOS/Xcode. Web dan Windows bukan target MVP.

### Fitur transaksi lokal
- Buat model pemasukan/pengeluaran dengan nominal integer unit minor dan formatting locale-aware untuk mata uang yang didukung.
- Buat repository SQLite dengan batasan nominal positif serta operasi baca, simpan, edit, hapus dan filter bulan.
- Buat layar ringkasan bulanan, filter jenis transaksi, daftar, form, edit, hapus, validasi, serta keadaan kosong/memuat/error.
- Pilih gaya hangat dan tenang; tema memakai warna tanah sebagai aksen dan netral hangat sebagai dasar.
- Tambah tes CRUD/filter/constraint SQLite dan tes widget aksi tambah serta validasi nominal.

### Tagihan, pengingat, dan pengaturan
- Tambah model tagihan, status, frekuensi sekali/mingguan/bulanan/tahunan, dan perhitungan tanggal berikutnya dengan clamp akhir bulan serta tahun kabisat.
- Tambah tabel SQLite untuk tagihan dan riwayat pembayaran, plus migrasi skema.
- Pembayaran berulang dicatat sebagai kejadian dan memajukan jatuh tempo; pembayaran sekali masuk status lunas.
- Tambah pengingat lokal untuk Android/iOS dengan zona waktu perangkat, izin diminta saat pengguna mengaktifkan reminder, dan jadwal inexact agar tidak meminta exact-alarm permission.
- Tambah izin Android untuk notifikasi setelah reboot dan receiver penjadwalan ulang.
- Tambah layar tagihan dengan form, validasi, daftar jatuh tempo/terlambat, edit, hapus, dan konfirmasi lunas.
- Tambah navigasi Catatan/Tagihan/Pengaturan.
- Tambah pengaturan mata uang, tanggal awal periode, toggle notifikasi, preferensi tema terang/gelap, dan hapus seluruh data dengan konfirmasi.
- Format input dan tampilan mata uang mengikuti locale; nominal pecahan disimpan sebagai integer unit minor.
- Migrasikan skema SQLite sampai versi 6, termasuk pengaturan tema gelap dan hari anchor pengulangan tanpa menghapus data versi sebelumnya.
- Perbaiki pengulangan bulanan/tahunan agar tanggal anchor tetap, contohnya tanggal 31 kembali ke 31 setelah bulan pendek, dan 29 Februari kembali saat tahun kabisat.
- Format nominal notifikasi mengikuti mata uang dan locale aktif, bukan selalu rupiah.
- Ganti label launcher Android dari `catat_uang` ke `Catat Uang`; label iOS sudah sesuai.
- Mata uang hanya dapat diganti saat belum ada transaksi atau tagihan, agar nominal lama tidak salah ditafsirkan.
- Tambah tes tagihan, pembayaran berulang, tanggal kalender, pengaturan SQLite, navigasi, dan validasi form.

### Verifikasi terakhir
- `dart format lib test`: lulus.
- `flutter analyze`: lulus tanpa temuan.
- `flutter test`: lulus, 17 tes, termasuk migrasi SQLite versi 4 ke 6, anchor pengulangan tanggal 31/tahun kabisat, dan formatting nominal reminder lintas mata uang.
- `flutter analyze`: lulus tanpa temuan setelah implementasi tema terang/gelap.
- 2026-10-05: Android SDK terpasang, APK debug berhasil dibuat di `mobile/build/app/outputs/flutter-apk/app-debug.apk` (158.6 MB).
- Aktifkan Android core library desugaring sesuai kebutuhan `flutter_local_notifications`.
- Alihkan `GRADLE_USER_HOME` ke `D:\\alfariz\\film\\pribadi\\project-golang\\.gradle-home` karena C: kehabisan ruang saat build; path Gradle tersimpan lokal.
- Matikan incremental Kotlin karena plugin di C: dan project di D: memicu cache path error.
- `flutter analyze`: bersih; `flutter test`: 17 tes lulus setelah setup Android.
- Emulator AVD API 37 belum boot: emulator berhenti/offline dengan C: tersisa sekitar 1.5 GB. AVD salinan di D: dan data emulator diarahkan ke D:, tetapi emulator masih gagal startup.
- 2026-10-15: Ruang C: bertambah menjadi sekitar 23.2 GB; emulator API 37 berhasil boot memakai AVD/data di D:.
- Instal APK awal via `adb install` gagal saat Android Package Manager belum siap; push APK ke `/data/local/tmp` lalu `pm install -r` berhasil.
- App diluncurkan di emulator; `topResumedActivity` menunjukkan `dev.catatuang.catat_uang/.MainActivity`, tanpa `FATAL EXCEPTION` di logcat.
- Uji emulator 2026-10-15: layar Catatan menampilkan ringkasan dan keadaan kosong; layar Tagihan menampilkan keadaan kosong dan tombol tambah; Pengaturan menampilkan mata uang, periode, tema, dan pengingat.
- Toggle pengingat memunculkan dialog izin Android; izin dikabulkan. Form tagihan terbuka dengan frekuensi, tanggal jatuh tempo, dan pilihan pengingat.
- Uji interaksi 2026-10-15 tidak menghasilkan bukti CRUD: tap koordinat tidak konsisten mengisi form dan hasil berupa `Itnt`/`Rp1` tidak sesuai input. Proses app/emulator yang sempat dimulai ulang juga membuat item tak terlihat, tetapi status persistensi SQLite belum bisa dipastikan karena input sebelumnya tak valid.
- Form tambah tagihan, pilihan pengingat, daftar dan menu aksi tampil; dialog izin notifikasi muncul dan izin dikabulkan. Dialog lunas bisa dibuka.
- Tampilan Catatan dan Tagihan dicek pada emulator 1080x2400; layout dan tombol navigasi terlihat. Tema gelap sempat ditoggle namun tidak terekam visual terverifikasi.
- SQLite persistensi, transaksi CRUD, pembayaran tersimpan, dan notifikasi saat tiba belum terverifikasi. Lanjutkan dengan automation Flutter/instrumentation, jangan mengandalkan koordinat tap untuk mengetik form.
- Build iOS memerlukan macOS/Xcode.
