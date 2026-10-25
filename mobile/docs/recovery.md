# Pemulihan setelah dataset server berubah

Flutter menyediakan peninjauan pemulihan saat identitas dataset berubah atau ledger lama belum memiliki pin dataset. Prosedur operator tetap wajib: [restore dan rotasi dataset](../../backend/docs/restore-sync.md). Fitur ini tidak memulihkan image emulator lama dan bukan pengganti backup eksternal.

## Memilih data yang dipertahankan

1. Masuk sebagai pemilik ledger, lalu jalankan **Sinkronkan sekarang**. Perubahan dataset menghentikan pengiriman tanpa menghapus catatan atau antrean.
2. Tekan **Tinjau pemulihan**. Aplikasi mengambil snapshot transaksi akun, termasuk penanda penghapusan, dengan identitas dataset terbaru. Tahap ini tidak mengganti catatan lokal dan tidak mengirim transaksi.
3. Bandingkan setiap catatan. Perbedaan yang sudah dikenal perangkat harus dipilih secara eksplisit: **Pertahankan perangkat** atau **Gunakan data akun**. Data identik dan catatan yang hanya ada di akun dipilih untuk menggunakan akun secara awal; pilihan tersebut tetap dapat diubah sebelum konfirmasi.
4. Memilih perangkat yang tidak memiliki catatan berarti mempertahankan penghapusan lokal. Jika akun masih mempunyai catatan tersebut, penghapusan akan masuk antrean. Memilih akun yang tidak mempunyai catatan menghapus salinan lokal saat pilihan diterapkan.
5. Tekan **Terapkan pemulihan**, lalu konfirmasi. Seluruh pilihan, mapping, pin dataset, cursor, serta antrean diterapkan dalam satu transaksi SQLite. Kondisi sebelum perubahan disimpan dalam transaksi yang sama sebagai cadangan lokal. Tagihan, pembayaran, pengingat, dan pengaturan tidak diganti.
6. Tekan **Sinkronkan sekarang** untuk mengirim pilihan perangkat. Pilihan ini memakai UUID record yang sama, versi dasar dari snapshot server, serta ID operasi baru. Konflik baru tetap diperiksa apabila akun berubah setelah peninjauan.

Batal/menutup peninjauan tidak menerapkan pilihan. Jika ada perubahan lokal sejak peninjauan dibuat, generasi ledger berubah, akun berganti, atau dataset dirotasi lagi, penerapan dihentikan dan perlu ditinjau ulang. Gangguan penulisan SQLite membatalkan seluruh transaksi, termasuk cadangan yang belum commit; tidak ada keadaan hasil pemulihan sebagian.

Peninjauan dibatasi hingga 5.000 catatan lokal/server dan 200 halaman riwayat. Data mata uang lain ditolak. Jika melebihi batas atau mapping antrean tidak konsisten, aplikasi mempertahankan data dan meminta pemeriksaan di luar alur ini. Cursor mundur dengan identitas server yang belum dirotasi tetap membutuhkan pemeriksaan operator.

## Mengembalikan kondisi sebelum pemulihan

Sesudah pemulihan, **Cadangan transaksi lokal** menampilkan daftar kondisi yang tersimpan untuk akun/server yang sama. Pilih tanggal lalu konfirmasikan **Pulihkan cadangan** untuk mengembalikan transaksi, mapping, pin, dan antrean sebelumnya. Kondisi saat ini juga dicadangkan sebelum penggantian, sehingga tidak langsung hilang saat mengembalikan cadangan.

Operasi inflight pada cadangan mempertahankan ID dan payload semula. Generasi lokal diganti agar respons jaringan lama tidak menulis ke hasil restore. Perubahan yang sudah diterima server **tidak dibatalkan** oleh restore lokal. Tinjau kembali dataset/sinkronisasi setelah mengembalikan cadangan. Pemulihan cadangan lokal dapat digunakan saat koneksi belum terverifikasi selama sesi pemilik masih tersedia.

Cadangan disimpan pada tabel `sync_recovery_backups` di database SQLite yang sama. Isinya hanya snapshot transaksi dan metadata sync; tidak memuat token/password, tagihan, pembayaran, atau pengaturan. Cadangan tidak diunggah dan belum memiliki ekspor/impor file eksternal. Kehilangan perangkat, kerusakan database, uninstall, atau **Hapus semua data lokal** dapat menghapus cadangan ini juga. Cadangan tidak dipangkas otomatis dan dapat menambah ukuran database.

## Pengujian

SQLite naik ke versi 9 dengan penambahan tabel cadangan, tanpa mengganti data atau pin yang sudah ada. Unit/widget tests mencakup pilihan eksplisit, pembatalan dialog, kegagalan penulisan yang diinduksi, perubahan lokal saat tinjauan, rotasi dataset kedua, ID record tetap, penghapusan, operasi legacy yang sudah diterima server, restore cadangan, dan migrasi 8 ke 9.

Tes backend nyata memakai dua file SQLite dan Go/PostgreSQL terisolasi. Dengan environment `SYNC_TEST_ROTATE_EXE` mengarah ke binary administrasi `sync-dataset`, skenario menjalankan rotasi pada **database tes**, mempertahankan pilihan perangkat B, lalu memulihkan A dari data akun. Workflow mobile membangun binary ini dan menjalankan skenario tersebut. Jangan mengarahkan environment pengujian ke database production.

Hasil lokal: 99 unit/widget tests lulus, analyze bersih, serta skenario dua SQLite/rotasi/pemulihan dengan backend nyata lulus terpisah. Ini bukan pengujian restore backup PostgreSQL production atau interaksi dua perangkat Android/native. Aplikasi tidak dipasang ke emulator pada tahap ini.
