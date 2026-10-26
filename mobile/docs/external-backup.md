# Backup file terenkripsi

Pengaturan → **Backup file terenkripsi** mengekspor transaksi, tagihan, riwayat pembayaran, pengaturan, penautan, antrean sinkronisasi, dan cadangan pemulihan lokal. Token serta kata sandi akun tidak disertakan. Pilih folder di luar data aplikasi, misalnya penyimpanan dokumen atau provider file yang Anda percayai.

File `.cuenc` dilindungi AES-256-GCM dan kunci dari PBKDF2-HMAC-SHA256 600.000 iterasi, salt acak 16 byte, nonce 12 byte, dan tag 16 byte. Metadata algoritma/versi diperiksa; payload diautentikasi. Enkripsi/dekripsi dilakukan di isolate agar UI tetap merespons. Implementasi menggunakan [cryptography](https://pub.dev/packages/cryptography) dan dialog native [file_picker](https://pub.dev/packages/file_picker), bukan algoritma enkripsi buatan sendiri.

Gunakan frasa sandi backup tersendiri minimal 15 karakter, maksimal 256 byte UTF-8, dan simpan secara terpisah. Frasa sandi tidak disimpan aplikasi dan tidak dapat direset. File rusak atau frasa salah tidak mengubah database. Batas file 20 MiB, payload 12 MiB, dan 100.000 baris.

**Pulihkan dari file** membaca/dekripsi file, menampilkan jumlah transaksi/tagihan/pembayaran, lalu meminta konfirmasi. Pemulihan hanya diizinkan jika tabel data lokal masih kosong. Pengaturan default boleh diganti, tetapi catatan, tagihan, antrean, penautan, atau cadangan yang sudah ada membuat restore ditolak. Ekspor data yang ada terlebih dahulu; jangan mengosongkan aplikasi tanpa backup yang sudah disimpan dan frasa sandinya diketahui.

Restore berlangsung dalam satu transaksi SQLite. UUID record dan ID/payload operasi inflight dipertahankan; generasi ledger lokal diganti untuk menolak respons jaringan lama. Token login tidak dipulihkan; masuk dengan akun/server pemilik antrean untuk melanjutkan sync. Perubahan dataset server tetap memerlukan peninjauan pemulihan. Tagihan dan pengingat direkonsiliasi setelah impor; izin notifikasi perangkat baru tetap perlu diperiksa.

Format payload versi 2 menyertakan tabel lokal yang dikenal, termasuk antrean/tagihan, dan menolak tabel/kolom asing. Payload versi 1 tetap dapat diimpor. File tidak dapat menjalankan SQL. Import tidak menggabungkan dua ledger atau mengubah server. Cadangan pemulihan di dalam SQLite ikut diekspor; berbeda dari file eksternal, salinan internal tetap dapat hilang saat uninstall atau database rusak.

Pengujian mencakup roundtrip terenkripsi, frasa salah, perubahan ciphertext, transfer dua database file, pembayaran, tema, antrean inflight, larangan menimpa target berisi, dan rollback data yang melanggar constraint. Dialog file Android/iOS memerlukan uji native tersendiri; build APK tidak membuktikan semua provider file berfungsi.
