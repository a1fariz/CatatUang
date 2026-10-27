# Uji Android dan batas bukti demo

Tanggal: 28 Oktober 2026. Pengguna belum memiliki perangkat khusus dan memilih demo/pengujian emulator dahulu. Tidak ada hasil di dokumen ini yang menyatakan Android fisik sudah diuji.

## Lingkungan dan identitas aplikasi

- Demo offline: `dev.catatuang.catat_uang.demo`, label **Catat Uang Demo**. Berisi ruang contoh dan ruang kosong terpisah; tidak memerlukan akun/server. Semua contoh fiktif. Buka ulang aplikasi untuk memilih ruang lainnya.
- Integration CI: `dev.catatuang.catat_uang.integration`, pada emulator disposable. API dan PostgreSQL fixture terpisah dari data pengguna.
- Paket reguler `dev.catatuang.catat_uang` tidak boleh diganti atau dihapus untuk pengujian. Jangan memakai ledger keuangan pribadi. Tidak ada uninstall atau clear-data reguler dalam prosedur ini.

## Matriks pengujian

| Skenario | Bukti otomatis/emulator | Yang tetap perlu diuji pada perangkat khusus |
|---|---|---|
| Pencatatan offline | Capture mematikan Wi-Fi/data pada emulator disposable, menambahkan Rp12.345 melalui UI, lalu memeriksa catatan setelah restart | Mode pesawat, pencatatan/edit/hapus, force-close normal dan buka ulang pada model/OS yang dipilih |
| Data contoh dan mulai kosong | Seed transaksi/tagihan/payment atomik, guard database demo, reopen/clear tanpa duplikasi, serta CTA transaksi pertama diuji | Kenyamanan alur pada layar/font/keyboard perangkat |
| Backup/restore | Native storage integration mentransfer file terenkripsi antar dua SQLite di emulator; tes codec juga mencakup password salah, tamper, target berisi, dan rollback | Dialog SAF Documents/provider pilihan, file benar-benar tersimpan di luar aplikasi, transfer antar instalasi kosong, pembatalan pemilih file dan pemulihan tanpa kehilangan data |
| Pengingat | Native integration memakai plugin Android asli untuk mendaftar jadwal, membaca ulang lewat adapter baru, dan membatalkannya | Izin ditolak/diterima, notifikasi benar-benar diterima, app ditutup, reboot, battery saver dan kebijakan vendor |
| Sinkronisasi | CI menjalankan dua ledger SQLite file terhadap Go/PostgreSQL nyata: retry, konflik, perubahan dataset dan pembayaran | Dua Android/perangkat terpisah, offline bersamaan, koneksi terputus, logout/login dan konflik melalui UI |

Dua ledger SQLite bukan dua Android fisik. Jadwal yang terdaftar bukan bukti notifikasi diterima. Video demo offline tidak menunjukkan sinkronisasi cloud atau ekspor/restore SAF selesai. Hasil eksekusi dan provenance media dirangkum dalam [demo](demo.md).

## Langkah uji perangkat saat tersedia

Catat model/versi Android, versi APK/source commit, application ID, waktu, kondisi jaringan/izin, hasil aktual, dan bukti screenshot untuk setiap kasus. Gunakan hanya perangkat khusus dan data fiktif. Simpan hasil **LULUS / GAGAL / BELUM DIUJI**, jangan menganggap langkah dalam daftar sebagai hasil eksekusi.

1. **Offline dan persistensi:** matikan koneksi perangkat tes, buka ruang kosong demo, catat pemasukan dan pengeluaran, periksa ringkasan/filter, tutup-buka aplikasi, dan cocokkan nominal/kategori/tanggal. Edit lalu hapus salah satu contoh dan periksa lagi setelah reopen. Pastikan ruang contoh tidak berubah oleh ruang kosong.
2. **Backup/restore melalui SAF:** di ruang contoh, buka Pengaturan → Backup file terenkripsi. Gunakan frasa tes baru minimal 15 karakter dan simpan file ke Documents/provider yang dipilih. Jangan tampilkan frasa pada screenshot/video. Buka ulang launcher, pilih ruang kosong yang benar-benar belum berisi ledger, lalu pilih file. Periksa preview dan jumlah transaksi/tagihan/payment, konfirmasi restore, dan cocokkan isinya. Batalkan jika ruang kosong sudah berisi catatan; gunakan instalasi tes baru/lingkungan kosong terpisah, bukan menghapus data pengguna.
3. **Kegagalan restore:** pada target tes kosong terpisah, coba password salah, salinan file yang dirusak, dan pembatalan pemilih dokumen. Pastikan tidak ada data setengah pulih. Pada target berisi, pastikan restore ditolak. Simpan salinan backup asli tetap utuh.
4. **Pengingat:** aktifkan izin melalui Pengaturan, buat tagihan fiktif dengan waktu pengingat yang masih di masa depan, dan catat jadwalnya. Periksa penerimaan saat app ditutup, setelah reboot, dan battery saver secara terpisah. UI menetapkan jam jatuh tempo berdasarkan kalender; jangan menganggap pengujian selesai hanya karena jadwal terlihat atau mengubah jam perangkat agar tampak berhasil. Nonaktifkan pengingat/hapus tagihan dan pastikan jadwal dibatalkan.
5. **Dua perangkat dan sinkronisasi:** gunakan build akun khusus tes pada server fixture yang tersedia, bukan APK demo offline. Masuk akun tes yang sama pada A/B, periksa bahwa login saja tidak mengirim data, tautkan transaksi/tagihan masing-masing dengan persetujuan, lalu sinkronkan manual. Buat perubahan offline pada kedua perangkat termasuk record yang sama, sambungkan dan periksa pilihan konflik, retry pembayaran, serta persistensi setelah reopen. Cocokkan nominal dan history di kedua perangkat. Gunakan [panduan transaksi](../mobile/docs/transaction-sync.md), [tagihan](../mobile/docs/bill-sync.md), dan [pemulihan](../mobile/docs/recovery.md).

## Kriteria pengalaman pertama

- Pengguna tanpa akun dapat langsung menemukan **Catat transaksi pertama**, memahami nominal/kategori/tanggal, dan kembali ke catatan tersimpan.
- Pengguna memahami bahwa lokal berarti tersimpan di perangkat; login tidak menautkan/mengirim data secara otomatis.
- Status antrean menunggu, masalah akun/konflik, dan waktu sinkronisasi terakhir terbaca. Antrean kosong tidak menyatakan server selalu terbaru.
- Status pada Catatan menjelaskan transaksi; penautan tagihan terpisah. Build tanpa API menyatakan fitur akun belum tersedia, bukan menampilkan sukses sinkronisasi palsu.
