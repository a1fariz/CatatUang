# Verifikasi email dan lupa kata sandi

Menu Akun menampilkan status email dari server, terpisah dari status sesi aktif. **Verifikasi email** mengirim kode ke alamat akun yang sudah disimpan server. **Lupa kata sandi** tersedia pada form masuk: masukkan email, minta kode, lalu isi kode serta password baru/konfirmasi. Server belum dikonfigurasi email akan menghasilkan pesan layanan belum tersedia, bukan mengklaim email terkirim.

Kode dimasukkan di field tersembunyi, dikirim melalui body POST tanpa query/redirect/retry otomatis, dan dibersihkan bersama field password sesudah permintaan selesai. Password minimal 15 karakter/maksimal 128 byte UTF-8, tanpa memangkas spasi. Request reset memberi pesan generik; kode lama tidak berlaku setelah request baru. Rate limit server menahan percobaan ulang sesuai Retry-After. Reset tidak otomatis login dan mencabut semua sesi; kembali ke form masuk dengan password baru. Ledger lokal tidak diubah oleh tindakan akun.

Status user yang diperiksa diperbarui sebagai metadata controller tanpa mengganti identitas sesi atau timer token. Keamanan sinkronisasi tetap memeriksa pemilik/server, expiry, serta sesi yang sama sebelum dan setelah request.

Validasi: tes kontrak HTTP memeriksa POST/no-query/no-redirect/status tepat, tes widget memeriksa validasi, submit ganda, penghapusan secret, dan refresh status terverifikasi. Tes auth/controller/screen lainnya lulus; regresi posisi tombol keluar setelah menu bertambah sudah diperbaiki dengan scrolling ke target yang benar-benar dapat ditekan. Analyzer bersih. Pengiriman provider nyata dan notifikasi email perangkat belum diuji karena layanan/perangkat belum tersedia.
