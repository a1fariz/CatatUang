# Sinkronisasi transaksi Flutter

Pembaruan 26 Oktober 2026: SQLite versi 9 menambahkan [peninjauan pemulihan dan cadangan lokal](recovery.md) di atas pin dataset versi 8. Verifikasi terbaru: analyze bersih, 112 unit/widget tests lulus, dan skenario dua SQLite dengan rotasi/pemulihan melalui backend nyata lulus terpisah. CI backend/mobile commit `63c6baf` juga sudah berhasil; hasil perubahan selanjutnya diperiksa terpisah.

Sinkronisasi transaksi tersedia secara opsional melalui **Pengaturan → Sinkronisasi transaksi** pada build yang memiliki `API_BASE_URL`. Pencatatan tanpa akun tetap berjalan. Tagihan, riwayat pembayaran, pengingat, dan pengaturan belum disinkronkan.

## Menggunakan sinkronisasi

1. Jalankan backend terbaru dan terapkan seluruh migrasi, termasuk `000003_transaction_sync.sql` dan `000004_sync_dataset.sql`. Konfigurasi build mengikuti [panduan akun](account.md).
2. Masuk melalui Pengaturan → Akun, lalu pastikan sesi berhasil diperiksa.
3. Tekan **Tautkan transaksi**, baca akun tujuan dan konfirmasi penautan. Penautan membuat antrean lokal; belum mengirim transaksi.
4. Tekan **Sinkronkan sekarang** untuk mengambil transaksi akun dan mengirim perubahan perangkat. Tidak ada upload otomatis pada login, startup, resume, atau perubahan lokal.
5. Jika catatan akun dan perangkat sama-sama berubah, buka peringatan konflik. Bandingkan nominal, kategori, tanggal, dan catatan, lalu pilih **Gunakan data akun** atau **Pertahankan perangkat**. Pilihan perangkat dikirim pada sinkronisasi berikutnya dan tetap diperiksa terhadap versi akun.

Setiap catatan memiliki UUID tersendiri. Dua catatan yang sengaja dibuat terpisah tetap dianggap dua transaksi walaupun isinya serupa; aplikasi tidak menghapus duplikat berdasarkan kemiripan nominal/tanggal.

## Penautan, mata uang, dan penghapusan

Ledger terikat ke satu identitas akun dan URL server lengkap. Keluar akun mempertahankan data, penautan, dan antrean. Masuk sebagai akun lain tidak mengirim antrean pemilik sebelumnya; masuk kembali sebagai pemilik untuk melanjutkan. Catatan lokal tetap terlihat dan dapat digunakan pada perangkat, termasuk saat keluar akun. Ini bukan pemisahan profil atau perlindungan akses lokal antar pengguna perangkat.

Mata uang aktif dikunci selama ledger tertaut, termasuk jika tidak ada transaksi aktif. Backend dapat menyimpan beragam mata uang, sedangkan ledger Flutter ini memakai satu mata uang. Halaman yang mengandung mata uang lain ditolak **seluruhnya**, termasuk perubahan cursor, agar nominal tidak ditafsirkan dengan mata uang keliru. Konversi dan ledger multi-mata-uang belum tersedia.

Menghapus satu transaksi tertaut menambahkan penghapusan ke antrean. Membuat lalu menghapus transaksi yang belum pernah dicoba dikirim membatalkan upload lokal itu. Operasi yang pernah dicoba tetap harus diperiksa melalui retry karena server mungkin sudah menerimanya.

**Hapus semua data lokal** menghapus transaksi/tagihan/pembayaran/pengaturan, antrean, mapping, penautan, dan cadangan transaksi lokal dalam satu transaksi SQLite. Sesi akun dan transaksi server tetap ada. Penghapusan lokal ini tidak mengirim penghapusan massal ke server. Request yang sudah berjalan mungkin sudah diterima server; respons terlambat tidak mengisi kembali ledger yang sudah dibersihkan. Menautkan ulang dan menyinkronkan dapat mengambil data server kembali.

## Ketahanan dan protokol

- Skema SQLite naik dari 6 ke 7 dengan tabel tambahan `sync_binding`, `sync_transactions`, dan `sync_outbox`; data keuangan lama dipertahankan dan tidak otomatis ditautkan.
- Penyimpanan/edit/hapus transaksi dan perubahan antreannya berada dalam transaksi SQLite yang sama. Database yang sedang dibuka dibagikan melalui satu future agar pembacaan startup bersamaan tidak membuka koneksi duplikat.
- Antrean menyimpan payload operasi, UUID record, UUID operasi, versi dasar, dan status. Token/password tidak ditulis ke antrean; token tetap melalui secure session storage.
- Perubahan yang belum dicoba boleh digabungkan. Operasi yang sudah ditandai inflight menjadi tetap: timeout atau restart mencoba ulang ID dan payload yang sama. Edit baru disimpan terpisah; acknowledgement operasi lama tidak menimpa edit baru.
- Hasil POST yang belum pasti diselesaikan sebelum pull agar echo dari operasi sendiri tidak dianggap konflik eksternal. Receipt diverifikasi terhadap ID, versi, status penghapusan, dan payload operasi.
- Pull menerapkan data dan cursor dalam satu transaksi SQLite. Versi lama/echo diabaikan. Remote edit terhadap transaksi yang masih memiliki antrean disimpan sebagai snapshot konflik, sementara isi lokal dipertahankan.
- Setiap penautan mempunyai generasi lokal acak. Acknowledgement, pull, dan penyelesaian konflik memeriksa generasi itu agar respons sebelum penghapusan lokal tidak menulis ke ledger baru.
- Request memeriksa pemilik akun/server dan sesi sebelum dikirim. Respons dari sesi yang sudah berubah tidak diterapkan; 401 tidak boleh menghapus sesi baru yang berbeda.
- HTTP memakai timeout 15 detik, respons maksimal 1 MiB, redirect nonaktif, dan pesan lokal. Satu proses manual dibatasi 100 operasi dan 50 halaman per putaran pull; hasil sebagian meminta sinkronisasi lanjutan. Konflik pada satu record tidak menghalangi record lain.

Kontrak server dan batas retensi/restore: [backend transaction sync](../../backend/docs/transaction-sync.md). Aplikasi membaca `/v1/sync/state` sebelum mengirim antrean, memin `dataset_id`, lalu menyertakan header `X-Sync-Dataset` pada request transaksi. Perubahan identitas maupun cursor yang mundur menghentikan sinkronisasi; pin/cursor/antrean tidak direset otomatis.

Operator wajib [merotasi identitas setelah restore](../../backend/docs/restore-sync.md); identitas dari backup tidak berubah sendiri. Ledger lama yang sudah pernah sinkron atau memiliki operasi inflight tanpa pin dataset tidak menerima identitas baru otomatis. Gunakan [Tinjau pemulihan](recovery.md) untuk membandingkan data, membuat pilihan eksplisit, dan menyimpan cadangan sebelum melanjutkan. Jangan menghapus data atau mengubah pin untuk melewati penghentian ini.

## Verifikasi

```powershell
flutter analyze --no-pub
flutter test --no-pub
```

Tes khusus backend nyata memakai dua **file database SQLite tes**, dua sesi akun, HTTP client nyata, serta Go/PostgreSQL dengan database tersendiri:

```powershell
flutter test --no-pub --dart-define=SYNC_TEST_API_URL=http://127.0.0.1:18089 test/sync_backend_test.dart
```

Jalankan API tes di alamat tersebut dengan database tes yang telah dimigrasikan. Tes membuat akun unik; jangan arahkan ke production. Tanpa define ini, skenario backend nyata dilewati oleh suite biasa. Workflow mobile memiliki job PostgreSQL/Go khusus agar skenario ini dapat berjalan di CI; CI commit awal sudah berhasil; hasil untuk perubahan selanjutnya diperiksa terpisah.

Verifikasi 25 Oktober 2026: 84 unit/widget tests lulus dan 1 skenario backend nyata lulus terpisah. Uji mencakup receipt hilang, antrean setelah reopen, edit saat inflight, konflik, tombstone, perbedaan akun/mata uang, data clear saat request berjalan, migrasi, validasi HTTP, persetujuan penautan, dan pilihan konflik. Dua database mewakili dua perangkat; pengujian ini bukan bukti interaksi dua perangkat Android/native. Tidak ada instalasi aplikasi ke emulator pada tahap ini.

## APK pengembangan terverifikasi

APK debug terbaru dibangun dari `lib/main.dart` dengan `API_BASE_URL=http://10.0.2.2:8080`, untuk backend pada host emulator. Hasil berada di `build/app/outputs/flutter-apk/app-debug.apk` dan salinan lokal `../.tools/catat-uang-sync-debug.apk` (folder tools diabaikan Git).

- Package: `dev.catatuang.catat_uang`, versi `1.0.0+1`.
- Tanda tangan diverifikasi dengan apksigner dan cocok dengan keystore debug asli: SHA-256 `c0480972ebad36974db01b30175f2fd6ef0af162fe12431afee759539c24578b`.
- Seluruh 24 file source Dart `lib/` cocok secara literal dengan source pada kernel APK; target integration akun tidak ditemukan di APK biasa.
- SHA-256 APK: `f4c5b22e4ef43adb9c0fc97e44bd86af4c75b5f0f97aa6858a546babd49ddce7`.

APK hanya dibangun dan diperiksa, belum dipasang/dijalankan untuk pengujian sinkronisasi Android. Backend tes sudah dihentikan dan tidak disertakan di dalam APK. Untuk perangkat fisik, buat build dengan endpoint HTTPS atau gunakan loopback dan USB reverse seperti pada panduan akun.
