# Tagihan dan pembayaran antarperangkat

Pengaturan → **Sinkronisasi tagihan dan pembayaran** memerlukan akun yang sudah diperiksa server. Penautan tagihan opt-in terpisah dari transaksi, tetapi pemilik akun, server, dan mata uang harus sama. Keluar akun tidak menghapus antrean. Sinkronisasi memproses retry inflight dahulu, mengambil feed, mengirim pending, lalu mengambil perubahan berikutnya.

SQLite versi 10 menyimpan UUID tagihan/pembayaran, versi server, cursor/dataset tagihan tersendiri, antrean pending/inflight/invalid, dan konflik. Simpan/bayar/hapus beserta antrean commit bersama. Edit tidak mengganti isi operasi inflight; acknowledgment merebase pending berikutnya. Pembayaran lokal tidak otomatis membuat transaksi pengeluaran.

Tagihan mempertahankan zona IANA asal. Perulangan dihitung dalam zona itu, termasuk DST dan hari akhir bulan. Jika dua perangkat membayar kejadian yang sama, versi stale ditolak. **Pertahankan lokal** membiarkan konflik berhenti. **Gunakan versi akun** mengganti tagihan dan history lokal itu setelah konfirmasi; ekspor backup terlebih dahulu untuk mempertahankan keduanya.

Dataset baru menghentikan sinkronisasi. **Tinjau pemulihan dataset tagihan** mengambil snapshot lengkap maksimum 2000 perubahan, menampilkan versi akun, lalu meminta konfirmasi. ID yang terdapat di akun memakai versi akun termasuk tombstone; tagihan hanya di perangkat dipertahankan dengan ID operasi baru. Kondisi lokal disalin ke `bill_sync_recovery_backups` sebelum perubahan dan ikut backup terenkripsi. Salinan ini belum memiliki tombol undo tersendiri. Review dibatalkan jika data lokal berubah; dataset diverifikasi ulang sebelum penerapan. Sinkronkan untuk melanjutkan antrean setelah review. Jangan mengosongkan data untuk melewati konflik.

Backup payload versi 2 mencakup semua tabel tagihan/sync; versi 1 tetap dapat diimpor. Token akun tidak ikut. Pengingat direkonsiliasi setelah sync/konflik/pemulihan; kegagalan penjadwalan dilaporkan tanpa membatalkan data. Batas server 512 KiB/2000 pembayaran per agregat; jangan menghapus history untuk melewati batas.

Validasi lokal: enam tes repository baru lulus. Suite Flutter menghasilkan 120 tes lulus, dua integrasi dilewati tanpa API, satu tes fixture backup diperbaiki lalu lulus bersama enam tes terarah. Integrasi nyata transaksi dan tagihan terhadap Go/PostgreSQL lulus. Analyzer bersih dan APK debug berhasil. Fixture migrasi 6/7/8 membuang skema versi 10 sebelum upgrade, sehingga menguji skema historis sebenarnya. Perangkat Android/iOS nyata belum diuji.
