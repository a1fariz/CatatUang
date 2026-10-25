# Ganti kata sandi

Fitur tersedia di **Pengaturan → Akun → Ganti kata sandi** setelah sesi berhasil diperiksa. Masukkan kata sandi lama, kata sandi baru, dan konfirmasi kata sandi baru. Kata sandi baru harus berbeda, minimal 15 karakter Unicode, dan maksimal 128 byte UTF-8; spasi tidak dipangkas.

Sesudah berhasil, sesi perangkat lain dicabut. Sesi yang mengirim permintaan tetap memakai token dan waktu kedaluwarsa semula; perubahan kata sandi tidak memperpanjang sesi. Transaksi, tagihan, pembayaran, cadangan, penautan akun, dan antrean SQLite tidak dihapus. Login berikutnya memakai kata sandi baru.

Kata sandi lama yang salah menghasilkan 422 dan tidak mengeluarkan sesi aktif. Token yang sudah dicabut/kedaluwarsa menghasilkan 401 dan sesi lokal dibersihkan. Permintaan dibatasi 20 percobaan per IP koneksi dan per akun untuk jendela 15 menit, terpisah dari bucket login/register. Respons 429 meminta cooldown sebelum form dapat dikirim lagi.

Jika koneksi putus setelah pengiriman, server mungkin sudah mengganti kata sandi. Aplikasi menampilkan hasil yang belum dapat dipastikan dan tidak mengirim ulang POST secara otomatis. Bila perlu, periksa akun dan coba masuk dengan kata sandi baru. Hanya respons 204 dianggap berhasil; respons sukses dengan format/status lain tidak dianggap konfirmasi perubahan.

Isian kata sandi dibersihkan setelah setiap pengiriman yang selesai, termasuk respons gagal atau belum pasti. Kata sandi tidak ditulis ke SQLite atau secure session storage. Token dan expiry sesi yang dipertahankan tidak ditulis ulang. Autofill memakai petunjuk kata sandi lama/baru; pengujian password manager native belum dilakukan.

Ini adalah penggantian kata sandi saat masih mengetahui kata sandi lama. Pemulihan lupa kata sandi, verifikasi email, dan reset melalui email belum tersedia. Request perangkat lain yang sudah diterima sebelum pencabutan sesi dapat selesai; request baru memakai token yang dicabut ditolak.

## Kontrak dan konsistensi

`POST /v1/auth/change-password` memakai Bearer dan JSON `current_password`, `new_password`; tidak menerima identitas pengguna dari body atau query. Server memverifikasi kata sandi, membuat hash Argon2id baru, memeriksa ulang hash dan validitas sesi di dalam transaksi, lalu mengganti hash serta mencabut sesi lain secara atomik.

Login mengambil row lock sebelum menerbitkan sesi dan memeriksa hash yang diverifikasi masih berlaku. Dengan demikian login yang sempat memverifikasi hash lama tidak dapat menerbitkan sesi setelah perubahan kata sandi commit. Kegagalan pencabutan sesi membatalkan perubahan hash juga. Hashing memakai slot kerja terbatas dan tidak dilakukan sambil memegang row lock pengguna.

## Verifikasi

Verifikasi lokal: 107 unit/widget tests lulus dan Flutter analyze bersih. Tes mencakup form/konfirmasi, pembersihan isian, rate limit, submit ganda, expiry/401, hasil jaringan yang tidak pasti, dan kontrak HTTP. Tes PostgreSQL dengan race detector mencakup pencabutan sesi lain, retensi expiry, hash baru, penolakan sandi lama, rollback saat pencabutan gagal, validasi ulang token di transaksi, serta login yang terhambat row lock saat hash berubah.

Skenario dua SQLite terhadap backend Go/PostgreSQL nyata juga memeriksa perubahan kata sandi, pencabutan sesi kedua, login dengan sandi baru, dan snapshot lokal yang tetap sama. Pengujian Android/iOS native untuk form ini belum dilakukan; APK hanya dibangun dan diperiksa tanpa pemasangan ke emulator.
