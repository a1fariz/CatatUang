# Verifikasi integrasi akun — 25 Oktober 2026

Catatan berikut merekam tahap integrasi akun sebelum sinkronisasi. Perkembangan terbaru tersedia di [sinkronisasi transaksi](transaction-sync.md); keterbatasan pengujian native dan insiden emulator di laporan ini tetap berlaku.

Implementasi ini menambahkan akun opsional pada Flutter. Catatan keuangan tetap memakai SQLite lokal dan belum disinkronkan atau dihubungkan ke pengguna server.

## Implementasi

- Daftar/login, konfirmasi password pendaftaran, penyembunyian password, validasi, penanganan error, dan cooldown rate limit.
- Token, identitas, dan expiry disimpan pada secure storage, terpisah per URL server. Penulisan dan penghapusan diverifikasi lewat readback; tidak ada fallback plaintext atau penyimpanan password pada SQLite/preferensi aplikasi.
- Pemulihan sesi, pemeriksaan `/v1/me`, kondisi offline yang belum terverifikasi, timer expiry, pemeriksaan resume, serta logout satu/seluruh sesi.
- Logout tetap menghapus token lokal ketika server tidak dapat dihubungi dan memberi tahu bahwa pencabutan server belum berhasil. Kegagalan storage menghalangi aksi akun sampai dicoba ulang.
- Account entry ada di Pengaturan; fitur lokal tidak menunggu login. Hapus data keuangan lokal tidak mencabut sesi akun, dan dialog menjelaskan batas tersebut.
- Android memakai izin internet, kebijakan HTTP debug terbatas ke loopback/emulator, dan pengecualian backup untuk preferensi secure storage. iOS memiliki entitlements Keychain dan accessibility hanya pada perangkat ini saat unlocked.

## Hasil pemeriksaan

| Pemeriksaan | Hasil |
|---|---|
| Format source dan test driver | Bersih |
| `flutter analyze --no-pub` | Tanpa temuan |
| `flutter test --no-pub` | 60 tes lulus |
| Build APK debug aplikasi biasa | Lulus |
| Source Dart dalam kernel APK | Cocok dengan seluruh 14 file `lib/` saat diperiksa |
| Endpoint development pada APK biasa | `http://10.0.2.2:8080` |
| Application ID APK biasa | `dev.catatuang.catat_uang` |
| Sertifikat APK biasa | Cocok dengan debug keystore lama pada profil pengguna |
| Source integration test pada kernel APK biasa | Tidak ikut menjadi target aplikasi utama |
| Build APK integration setelah perbaikan package | Application ID `dev.catatuang.catat_uang.integration` terverifikasi dari APK |
| Uji native awal pada emulator API 37 + backend/database nyata | Satu skenario lulus; lihat insiden instalasi di bawah |
| Uji ulang native setelah perbaikan isolasi | Tidak selesai: emulator salinan dan AVD baru tetap offline/gagal mencapai boot selesai |

Uji native awal menguji daftar/login, readback secure storage native, pemulihan melalui controller/adapter baru, token yang dicabut dari klien lain, logout, dan catatan fixture yang tetap tersedia. Hasil itu tidak membuktikan bahwa data aplikasi emulator lama selamat dari proses installer.

Uji ulang setelah perbaikan package tidak dinyatakan lulus. Kegagalannya terjadi saat boot, sebelum pemasangan APK/skenario aplikasi pada percobaan terakhir. Karena itu perbandingan metadata instalasi package biasa pada percobaan terakhir belum dapat diverifikasi. Data hasil mentah yang belum menjalankan pemeriksaan instalasi tidak boleh ditafsirkan sebagai bukti instalasi berubah atau tetap sama.

## Cakupan tes otomatis

Unit/widget tests mencakup kontrak HTTP, pembatasan redirect, deadline, respons malformed/terlalu besar, sanitasi error, isolasi token antar server, persistence adapter mock, kegagalan baca/tulis/hapus storage, pemulihan offline, 401/expiry, verifikasi terlambat setelah expiry, cooldown 429, duplicate submit, identitas tidak sesuai, validasi form, dan pencatatan lokal setelah login/logout. Tes keuangan/migrasi/pengingat sebelumnya tetap lulus.

Pemeriksaan iOS terbatas pada source dan XML entitlements yang direferensikan tiga konfigurasi signing. Build/perangkat iOS, backup/restore, reinstall, reboot, dan kondisi production belum diuji. Workflow mobile sudah ditambahkan tetapi belum dieksekusi pada GitHub Actions.

## Insiden instalasi emulator dan mitigasi

Pada pengujian native pertama, proses memakai `ANDROID_USER_HOME` berbeda dari build lama. Gradle membuat debug keystore di direktori tersebut. APK dengan application ID biasa kemudian memiliki tanda tangan berbeda, sehingga Flutter otomatis menghapus instalasi lama sebelum memasang APK tes. Penghapusan tersebut juga menghapus data aplikasi lama di emulator. Pemulihan data lama belum terverifikasi.

Pemeriksaan lokal belum menemukan cadangan database sebelum insiden yang terverifikasi. Metadata image userdata yang diperiksa tidak menyediakan snapshot internal untuk langsung memulihkan keadaan lama. Image asli setelah insiden dipertahankan; pengujian berikutnya memakai salinan image lalu AVD baru di `.tools`, bukan menulis ulang image tersebut. Salinan setelah insiden bukan cadangan sebelum penghapusan dan tidak boleh dianggap sebagai pemulihan.

Mitigasi yang ditambahkan:

1. Target integration memakai application ID terpisah untuk semua mode build.
2. Penanda Gradle eksplisit dan dart-define menjaga isolasi meskipun Flutter mengganti target dengan listener sementara; deteksi folder saja ternyata tidak cukup.
3. Application ID APK tes diperiksa sebelum pemasangan. APK biasa diperiksa kembali agar ID-nya normal dan sertifikatnya cocok dengan keystore lama.
4. `ANDROID_USER_HOME` untuk build biasa memakai profil pengguna lama, bukan direktori AVD alternatif. Debug keystore yang sempat dibuat pada direktori AVD ditambahkan ke `.gitignore`.
5. Dokumentasi meminta AVD/data pengujian khusus. Driver prebuilt tersedia agar kompilasi dan emulator dapat dijalankan terpisah; hasilnya dibatasi tiga menit setelah koneksi driver.

Jangan mengatasi konflik tanda tangan dengan menghapus aplikasi pengguna yang memiliki data. Verifikasi package, sertifikat, serta cadangan terlebih dahulu. Jika ada data penting pada emulator lama, perlakukan image yang dipertahankan sebagai bahan pemeriksaan lanjutan; laporan ini tidak menyatakan data itu sudah kembali.

## Artefak dan tahap berikutnya

APK aplikasi biasa: `build/app/outputs/flutter-apk/app-debug.apk`. Ini build debug untuk backend development pada host emulator, bukan rilis production. Panduan: [account.md](account.md).

Selanjutnya: desain pemetaan data lokal ke akun, UUID mapping, outbox, protokol sync, konflik, dan tombstone. Login saat ini tidak mengunggah atau mengimpor catatan. Pengembangan verifikasi email, pemulihan akun, dan kebijakan sesi production tetap terpisah dari perubahan ini.
