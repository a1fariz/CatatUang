# Mengelola sesi masuk

Buka **Pengaturan → Akun → Lihat sesi masuk** setelah sesi akun berhasil diperiksa. Daftar menampilkan waktu masuk, waktu berakhir, dan penanda **Sesi ini**. Setiap login membuat satu sesi; beberapa sesi dapat berasal dari perangkat fisik yang sama. Jenis perangkat, lokasi, alamat IP, token, dan hash token tidak ditampilkan.

Untuk mengakhiri login lain, tekan **Cabut**, periksa waktu sesi pada dialog, lalu konfirmasikan **Cabut sesi**. Login yang dicabut perlu masuk kembali. Sesi yang sedang dipakai tidak dapat dicabut dari daftar; gunakan **Keluar dari akun**. Pencabutan tidak menghapus transaksi, tagihan, pembayaran, cadangan, atau antrean SQLite, baik pada sesi ini maupun aplikasi perangkat lain.

Daftar diperbarui setelah percobaan pencabutan dan juga dapat diperbarui melalui tombol refresh. Jika koneksi terputus, pencabutan mungkin sudah diterima server; aplikasi mengambil daftar terbaru tanpa mengulang DELETE otomatis. Sesi yang sudah hilang ditangani sebagai daftar yang perlu diperbarui, tanpa menghapus sesi aktif. Token pemanggil yang sudah dicabut/kedaluwarsa menghasilkan 401 dan dibersihkan dari secure storage.

Daftar hanya memuat sesi yang belum kedaluwarsa, dengan sesi saat ini di urutan pertama. Aplikasi mengambil 50 item per halaman. **Muat sesi berikutnya** mengambil halaman berikut; ID duplikat antarhalaman diabaikan karena login/pencabutan dapat terjadi selama peninjauan. Refresh mengulang dari halaman pertama. Tidak ada polling latar belakang atau perpanjangan masa sesi dari membuka halaman ini.

## Backend

- `GET /v1/auth/sessions?limit=50&offset=0`, juga mendukung HEAD.
- `DELETE /v1/auth/sessions/{id}` untuk satu sesi aktif lain milik akun pemanggil.
- Seluruh endpoint memakai Bearer. Identitas pemilik berasal dari sesi, bukan body/query. JSON daftar hanya berisi `id`, `current`, `created_at`, dan `expires_at` dalam envelope pagination.
- ID publik UUID terpisah dari token/hashes dan tidak dapat dipakai untuk autentikasi. Sesi asing, kedaluwarsa, atau sudah dicabut menghasilkan 404; mencabut sesi sendiri menghasilkan 422.
- Migrasi tambahan `000005_session_ids.sql` memberi ID publik pada sesi lama tanpa mengganti token, hash, atau expiry. Migrasi lama tidak diubah. Penambahan kolom dengan UUID acak memerlukan penulisan baris yang sudah ada; jadwalkan migrasi tabel besar pada jendela pemeliharaan.
- Pencabutan mengambil row lock pengguna dan memeriksa lagi sesi pemanggil di dalam transaksi. Logout/logout-all memakai urutan lock yang sama dengan login dan ganti kata sandi. Token yang dicabut saat menunggu lock tidak dapat melanjutkan penghapusan sesi lain.

Pencabutan berlaku untuk request baru. Permintaan yang sudah diterima sebelumnya dapat selesai. Sesi tetap memiliki masa berlaku 24 jam; refresh token, verifikasi email, dan pemulihan lupa kata sandi belum tersedia.

## Verifikasi

112 unit/widget tests lulus dan Flutter analyze bersih. Tes memeriksa konfirmasi/cancel, perlindungan sesi aktif, pagination/validasi respons, retensi secure token, dan penanganan 401/404. Tes PostgreSQL dengan race detector memeriksa isolasi akun, tidak bocornya token, sesi kedaluwarsa, pagination, autentikasi ulang setelah menunggu lock, dan migrasi sesi lama.

Skenario dua SQLite terhadap Go/PostgreSQL nyata berhasil mencabut sesi kedua, mempertahankan sesi pemanggil, dan membuktikan snapshot transaksi/antrean kedua perangkat tetap sama. Login ulang, ganti kata sandi, serta pemulihan dataset tetap diperiksa dalam skenario itu. Ini bukan uji dua perangkat Android/native; APK dibangun dan diperiksa tanpa dipasang ke emulator.
