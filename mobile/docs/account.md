# Integrasi akun Flutter

Halaman **Pengaturan → Akun** menyediakan daftar, login, pemeriksaan sesi, serta logout satu/seluruh perangkat. Pencatatan SQLite tidak memerlukan akun. Login/logout tidak mengunggah, mengimpor, mengaitkan, atau menghapus catatan lokal. [Sinkronisasi transaksi](transaction-sync.md) memakai persetujuan penautan terpisah dan tombol manual di Pengaturan.

## Menjalankan untuk pengembangan

Siapkan backend sesuai `../../backend/README.md`, jalankan `migrate up`, lalu API. Untuk emulator Android bawaan, alamat `10.0.2.2` merujuk host pengembangan:

```powershell
flutter pub get
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080
```

`API_BASE_URL` adalah root layanan, bukan endpoint `/v1`. URL adalah konfigurasi build, bukan input pengguna. Tanpa nilai ini, aplikasi tetap berjalan dengan fitur lokal dan halaman Pengaturan menjelaskan bahwa akun belum diaktifkan. Konfigurasi yang tidak valid juga menonaktifkan fitur akun tanpa menghalangi pencatatan.

Untuk perangkat fisik Android melalui USB, gunakan `adb reverse tcp:8080 tcp:8080` dan build debug dengan `API_BASE_URL=http://127.0.0.1:8080`, atau gunakan server HTTPS. Jangan memasukkan token/password dalam URL atau dart-define.

Pada Windows tanpa Developer Mode, runner desktop yang bukan target proyek dapat dinonaktifkan hanya untuk proses terminal tersebut:

```powershell
$env:FLUTTER_WINDOWS = 'false'
$env:FLUTTER_LINUX = 'false'
flutter pub get
```

Pengaturan global Flutter/Windows tidak perlu diubah. Jika memakai cache dan Gradle pada drive D seperti mesin ini, atur `PUB_CACHE` ke folder `.pub-cache` mobile dan `GRADLE_USER_HOME` ke `../.gradle-home` sebelum pub get/build.

## Transport dan secure storage

- Release/profile hanya menerima HTTPS. Debug mengizinkan HTTP untuk localhost, 127.0.0.1, ::1, dan alias emulator 10.0.2.2. Android memiliki network security config terpisah untuk debug; cleartext di luar host tersebut tetap ditolak.
- Tidak ada bypass pemeriksaan sertifikat dan request autentikasi tidak mengikuti redirect. Timeout 15 detik dan batas respons 64 KiB mencegah penantian/ukuran respons tanpa batas. POST login/register tidak di-retry otomatis.
- Password hanya digunakan untuk request dan form, tidak ditulis ke SQLite, file preferensi, atau secure session. Pesan error dipetakan oleh aplikasi dan tidak menampilkan body error mentah dari server.
- Satu record sesi berisi token, expiry, dan identitas akun, disimpan melalui `flutter_secure_storage`. Key dipisahkan berdasarkan URL server lengkap agar token development tidak dipakai untuk server lain. Proses tulis dan hapus diverifikasi dengan membaca ulang.
- iOS menggunakan Keychain accessibility `unlocked_this_device`; entitlements Keychain disertakan pada Debug/Profile/Release. iOS tetap memerlukan macOS/Xcode serta konfigurasi signing yang sesuai; pengujian iOS belum dilakukan.
- Android memakai konfigurasi cipher bawaan plugin. File preferensi `FlutterSecureStorage.xml` dan `FlutterSecureKeyStorage.xml` dikecualikan dari backup cloud dan device transfer. Aturan ini tidak mengubah backup SQLite yang sebelumnya berlaku. Uji restore/transfer perangkat belum dilakukan.

Referensi: [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage), [HTTP client Dart](https://pub.dev/packages/http), dan [Android Network Security Configuration](https://developer.android.com/privacy-and-security/security-config).

iOS tidak diberi pengecualian ATS HTTP dalam perubahan ini. Gunakan endpoint HTTPS untuk pengujian iOS; jangan melonggarkan ATS secara global untuk mengikuti contoh HTTP emulator Android.

## Siklus sesi

1. Startup membaca secure storage tanpa menahan layar keuangan lokal, lalu memanggil `/v1/me`.
2. Respons valid mengaktifkan status sesi. Saat offline/timeout, sesi yang belum kedaluwarsa dipertahankan dengan label belum dapat diperiksa.
3. Token kedaluwarsa secara lokal, respons 401, atau identitas akun yang tidak sesuai menghapus sesi. Timer expiry berjalan saat aplikasi aktif; resume memeriksa sesi lagi.
4. Logout mencoba mencabut sesi di server lalu menghapus token lokal. Jika server tidak dapat dihubungi, aplikasi tetap menghapus token dan menjelaskan bahwa pencabutan server belum berhasil. Sesi server tetap tunduk pada expiry backend.
5. Kegagalan secure storage tidak dialihkan ke penyimpanan plaintext. Aksi akun diblokir sampai penyimpanan dapat dicoba ulang; fitur pencatatan tetap berjalan. Jika penyimpanan token baru gagal, aplikasi mencoba mencabut token tersebut.
6. Respons 429 menghormati cooldown `Retry-After` sebelum form dapat dikirim lagi. Tombol ganda tidak menghasilkan dua request autentikasi bersamaan.

Sesi berlaku 24 jam mengikuti backend. Refresh token, reset/ganti password, dan verifikasi email belum tersedia. Hapus semua data lokal menghapus transaksi/tagihan/pengaturan serta antrean dan penautan sinkronisasi SQLite; dialog menjelaskan bahwa sesi akun dan data server tidak ikut dihapus. Operasi yang sudah dikirim mungkin sudah diterima server. Lihat [aturan sinkronisasi](transaction-sync.md).

## Pengujian

```powershell
flutter analyze --no-pub
flutter test --no-pub
```

Unit/widget tests menguji HTTP, token, origin server, secure-storage adapter dengan platform mock, kegagalan storage, offline restore, 401/expiry, race verifikasi/expiry, rate limit, form, dan pencatatan yang tetap ada setelah login/logout. Platform mock tidak membuktikan penyimpanan native.

Untuk plugin native dan backend nyata, gunakan emulator Android serta backend dengan **database pengujian tersendiri**:

```powershell
$env:ORG_GRADLE_PROJECT_catatUangIntegrationTest = 'true'
try {
    flutter test integration_test/account_backend_test.dart -d EMULATOR_ID --no-pub --dart-define=AUTH_TEST_API_URL=http://10.0.2.2:58083
} finally {
    Remove-Item Env:ORG_GRADLE_PROJECT_catatUangIntegrationTest -ErrorAction SilentlyContinue
}
```

Test membuat email unik, menguji daftar/login, menulis/membaca token native, membuat ulang controller/adapter untuk pemulihan sesi, mencabut sesi dari klien lain, lalu logout. SQLite test memakai file baru dan hanya file itu yang dihapus setelah selesai. Token untuk URL test dibersihkan; karena itu gunakan URL test berbeda dari server akun pengembangan sehari-hari. Jangan arahkan tes ke production.

Konfigurasi Android memakai package `dev.catatuang.catat_uang.integration` untuk penanda Gradle di atas, target folder `integration_test`, atau dart-define `INTEGRATION_TEST=true`/`AUTH_TEST_API_URL`. Penanda eksplisit tetap diperlukan sebagai perlindungan ketika Flutter mengganti target dengan listener sementara. Isolasi package berlaku pada seluruh mode build, bukan hanya debug. Hapus penanda sebelum membangun APK aplikasi biasa. Sebelum memasang APK tes pada perangkat yang sudah memiliki data, periksa application ID APK. Gunakan AVD/data emulator khusus pengujian dan jangan mengarahkan data image ke emulator harian. Hindari mengganti `ANDROID_USER_HOME` untuk proses build karena nilai itu juga mengubah lokasi debug keystore; `ANDROID_AVD_HOME` dapat dipisahkan untuk konfigurasi emulator.

Target integration dilewati jika `AUTH_TEST_API_URL` kosong. Test ini memverifikasi pemulihan lewat controller/adapter baru; belum mensimulasikan reboot perangkat, backup/restore, atau reinstall aplikasi.

Untuk memisahkan beban kompilasi dan emulator, bangun APK target integration terlebih dahulu dengan penanda yang sama, simpan ke lokasi terpisah, lalu gunakan driver yang tersedia:

```powershell
flutter drive --driver=test_driver/account_driver.dart --target=integration_test/account_backend_test.dart --use-application-binary=PATH_APK_INTEGRATION -d EMULATOR_ID --no-pub
```

APK prebuilt harus memang berisi target integration, URL backend pengujian yang benar, dan application ID `.integration`. Driver membatasi penantian hasil tes tiga menit. Jangan mengganti path ini dengan APK aplikasi biasa.

Setelah integration test membangun target test, buat kembali APK aplikasi biasa sebelum dibagikan:

```powershell
flutter build apk --debug --no-pub --target lib/main.dart --dart-define=API_BASE_URL=http://10.0.2.2:8080
```

Workflow `mobile.yml` menyiapkan format, analyze, unit/widget tests, dan build Android. Pengujian emulator dengan backend membutuhkan environment tambahan dan tidak dijalankan oleh workflow ini.
