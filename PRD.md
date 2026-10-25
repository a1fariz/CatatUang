# PRD: Catat Uang

## 1. Ringkasan

Catat Uang adalah aplikasi pencatat keuangan pribadi untuk mencatat pemasukan, pengeluaran, dan tagihan. Aplikasi mobile dibuat dengan Flutter. Pengguna dapat mencatat dan melihat data tanpa internet. Notifikasi tagihan dijadwalkan di perangkat.

Backend Go dengan PostgreSQL menyediakan akun dan sinkronisasi lintas perangkat pada fase lanjutan. MVP berfokus pada pengalaman lokal, tanpa login dan tanpa backend.

## 2. Tujuan

- Mencatat pemasukan dan pengeluaran harian dengan cepat.
- Melihat transaksi dan ringkasan keuangan per bulan.
- Mencatat tagihan dan mendapat pengingat sebelum jatuh tempo.
- Tetap bisa memakai fitur utama tanpa koneksi internet.
- Menyediakan jalur pengembangan bertahap ke backend Go.

## 3. Bukan tujuan MVP

- Menghubungkan rekening bank, kartu, atau e-wallet.
- Membaca SMS atau notifikasi transaksi secara otomatis.
- Membayar tagihan dari aplikasi.
- Berbagi akun atau anggaran dengan pengguna lain.
- Analisis investasi, anggaran kompleks, atau prediksi pengeluaran.
- Sinkronisasi cloud, login, dan multi-perangkat.

## 4. Pengguna sasaran

Individu yang ingin mencatat transaksi pribadi dan mengingat jadwal tagihan. Produk tidak ditujukan sebagai aplikasi akuntansi bisnis.

## 5. Platform dan teknologi

### MVP

- Mobile: Flutter dan Dart.
- Penyimpanan: SQLite lokal.
- Pengingat: notifikasi lokal perangkat.
- Mata uang: satu mata uang pilihan pengguna, dengan IDR sebagai nilai awal.

### Fase backend

- API: Go REST API.
- Database server: PostgreSQL.
- Autentikasi: akun pengguna dan token akses.
- Sinkronisasi: API mengirim perubahan lokal dan mengambil perubahan server.

Pilihan package Flutter untuk akses SQLite, state management, dan notifikasi ditetapkan saat implementasi setelah memeriksa kebutuhan platform dan dukungan package. PRD tidak mewajibkan library tertentu.

## 6. Ruang lingkup MVP

### 6.1 Transaksi

- Tambah transaksi pemasukan atau pengeluaran.
- Isi nominal, kategori, tanggal, dan catatan opsional.
- Lihat daftar transaksi, transaksi terbaru tampil lebih dulu.
- Filter transaksi berdasarkan rentang bulan dan jenis transaksi.
- Ubah atau hapus transaksi.
- Tampilkan total pemasukan, total pengeluaran, dan selisih untuk bulan yang dipilih.

### 6.2 Kategori

- Sediakan kategori bawaan untuk pemasukan dan pengeluaran.
- Pengguna dapat memilih kategori saat membuat transaksi.
- Kategori khusus, penghapusan kategori bawaan, dan pengelolaan kategori lanjutan tidak termasuk MVP.

### 6.3 Tagihan

- Tambah tagihan dengan nama, nominal, tanggal jatuh tempo, dan frekuensi.
- Frekuensi MVP: sekali, mingguan, bulanan, tahunan.
- Pilih waktu pengingat sebelum tanggal jatuh tempo.
- Lihat tagihan mendatang dan tagihan lewat jatuh tempo.
- Tandai tagihan sebagai lunas.
- Tagihan berulang membuat kejadian tagihan berikutnya setelah kejadian saat ini ditandai lunas.
- Ubah atau hapus tagihan.

### 6.4 Notifikasi lokal

- Jadwalkan notifikasi pada waktu yang dipilih untuk setiap tagihan.
- Minta izin notifikasi saat pengguna pertama kali mengaktifkan pengingat, bukan tanpa konteks.
- Tampilkan kondisi izin ditolak dan sediakan arah ke pengaturan perangkat bila sistem mengizinkan.
- Jadwal notifikasi diperbarui saat tagihan atau waktu pengingat berubah.
- Batalkan notifikasi saat tagihan dihapus atau ditandai lunas.
- Notifikasi lokal hanya berjalan sesuai kemampuan dan kebijakan sistem operasi. Aplikasi tidak menjamin pengiriman saat izin dicabut, aplikasi dibatasi sistem, atau perangkat tidak aktif.

### 6.5 Pengaturan

- Pilih mata uang dari daftar yang didukung aplikasi.
- Pilih awal bulan untuk ringkasan bulanan, default tanggal 1.
- Atur preferensi notifikasi.
- Hapus semua data lokal melalui tindakan konfirmasi.

## 7. Alur pengguna

### 7.1 Penggunaan pertama

1. Pengguna membuka aplikasi.
2. Aplikasi menjelaskan penyimpanan lokal dan bahwa login belum tersedia.
3. Pengguna masuk ke ringkasan bulan berjalan.
4. Aplikasi menampilkan keadaan kosong dengan aksi untuk menambah transaksi.
5. Aplikasi tidak meminta izin notifikasi sampai pengguna mengaktifkan pengingat tagihan.

### 7.2 Tambah transaksi

1. Pengguna memilih tambah transaksi.
2. Pengguna memilih pemasukan atau pengeluaran.
3. Pengguna mengisi nominal, kategori, tanggal, dan catatan opsional.
4. Aplikasi memvalidasi input.
5. Aplikasi menyimpan transaksi di SQLite.
6. Aplikasi memperbarui daftar dan ringkasan tanpa menunggu jaringan.

### 7.3 Edit atau hapus transaksi

1. Pengguna membuka detail transaksi.
2. Pengguna memilih edit atau hapus.
3. Saat edit, aplikasi memvalidasi dan menyimpan perubahan.
4. Saat hapus, aplikasi meminta konfirmasi.
5. Aplikasi memperbarui ringkasan setelah perubahan berhasil.

### 7.4 Tambah tagihan dan pengingat

1. Pengguna membuka halaman tagihan dan memilih tambah.
2. Pengguna mengisi nama, nominal, jatuh tempo, frekuensi, dan waktu pengingat.
3. Jika pengingat aktif, aplikasi meminta izin notifikasi bila belum tersedia.
4. Aplikasi menyimpan tagihan secara lokal.
5. Aplikasi menjadwalkan notifikasi jika izin tersedia.
6. Jika izin tidak tersedia, tagihan tetap tersimpan dan aplikasi menampilkan status pengingat tidak aktif.

### 7.5 Tandai tagihan lunas

1. Pengguna memilih tagihan dan menandainya lunas.
2. Aplikasi menyimpan status lunas dan waktu pembayaran.
3. Aplikasi membatalkan notifikasi untuk kejadian yang telah lunas.
4. Untuk tagihan berulang, aplikasi membuat kejadian berikutnya sesuai frekuensi.

### 7.6 Pemulihan data lokal

1. Aplikasi dibuka kembali.
2. Aplikasi memuat transaksi, tagihan, dan pengaturan dari SQLite.
3. Aplikasi merekonsiliasi notifikasi terjadwal dengan tagihan yang masih aktif, bila platform mendukung pemeriksaan tersebut.

## 8. Aturan bisnis dan validasi

### Transaksi

- Nominal harus lebih besar dari nol.
- Nominal disimpan sebagai bilangan bulat dalam unit terkecil mata uang untuk mencegah kesalahan pembulatan floating point.
- Jenis transaksi hanya pemasukan atau pengeluaran.
- Kategori wajib dipilih dan harus cocok dengan jenis transaksi.
- Tanggal transaksi wajib valid.
- Catatan opsional, dibatasi panjangnya agar penyimpanan dan tampilan tetap terkendali.
- Perubahan dan penghapusan transaksi harus tercermin di ringkasan bulan terkait.

### Tagihan

- Nama wajib diisi.
- Nominal harus lebih besar dari nol.
- Tanggal jatuh tempo wajib valid.
- Frekuensi berulang harus menghasilkan tanggal kejadian berikutnya yang valid.
- Untuk pengulangan bulanan pada tanggal yang tidak tersedia di bulan tujuan, gunakan hari terakhir pada bulan tujuan.
- Status tagihan: aktif, lunas, atau dibatalkan.
- Tagihan lunas tidak boleh memicu pengingat untuk kejadian yang sudah dibayar.
- Menghapus tagihan membatalkan pengingat terkait.

### Ringkasan

- Ringkasan hanya menghitung transaksi dalam bulan dan tahun terpilih.
- Total pemasukan adalah jumlah transaksi pemasukan.
- Total pengeluaran adalah jumlah transaksi pengeluaran.
- Selisih adalah pemasukan dikurangi pengeluaran.
- Transaksi yang dihapus tidak dihitung.

### Data dan waktu

- Simpan waktu secara konsisten dan tampilkan tanggal mengikuti zona waktu perangkat.
- Perubahan zona waktu tidak boleh mengubah tanggal kalender transaksi secara tidak sengaja.
- Semua ID lokal stabil dan unik. Fase sinkronisasi harus dapat memetakan ID lokal ke ID server.

## 9. Data utama

### Transaction

- `id`: ID unik.
- `type`: income atau expense.
- `amountMinor`: nominal dalam unit terkecil mata uang.
- `currencyCode`: kode mata uang.
- `categoryId`: ID kategori.
- `occurredAt`: tanggal transaksi.
- `note`: catatan opsional.
- `createdAt`, `updatedAt`: waktu pembuatan dan perubahan.

### Category

- `id`: ID unik.
- `name`: nama kategori.
- `type`: income atau expense.
- `isDefault`: penanda kategori bawaan.

### Bill

- `id`: ID unik.
- `name`: nama tagihan.
- `amountMinor`: nominal dalam unit terkecil mata uang.
- `currencyCode`: kode mata uang.
- `dueAt`: tanggal kejadian tagihan.
- `recurrence`: once, weekly, monthly, yearly.
- `reminderOffset`: waktu pengingat sebelum jatuh tempo, atau kosong jika nonaktif.
- `status`: active, paid, cancelled.
- `paidAt`: waktu pelunasan, kosong bila belum lunas.
- `createdAt`, `updatedAt`: waktu pembuatan dan perubahan.

### Settings

- `currencyCode`: mata uang aktif.
- `monthStartDay`: tanggal awal bulan ringkasan.
- `notificationsEnabled`: preferensi pengingat.

## 10. Keadaan antarmuka yang wajib

Setiap layar data menyediakan keadaan relevan berikut:

- Kosong: belum ada transaksi atau tagihan, dengan aksi yang sesuai.
- Memuat: data lokal sedang dibaca atau operasi sedang berlangsung.
- Gagal: operasi penyimpanan atau pembacaan gagal, tampilkan pesan dan opsi mencoba lagi.
- Berhasil: perubahan tersimpan dan tampilan diperbarui.

Operasi lokal tidak boleh menampilkan status sinkronisasi jaringan pada MVP karena sinkronisasi belum tersedia.

## 11. Persyaratan non-fungsional

- Aplikasi dapat membuka data tersimpan tanpa koneksi internet.
- Input nominal dan tanggal divalidasi sebelum disimpan.
- Penghapusan semua data memerlukan konfirmasi eksplisit.
- Data pengguna tidak dikirim ke server pada MVP.
- Pesan kesalahan menjelaskan tindakan yang bisa dilakukan pengguna, tanpa menampilkan stack trace.
- Antarmuka mendukung ukuran layar ponsel umum, teks tidak terpotong, dan tombol utama mudah disentuh.
- Form, dialog, dan navigasi mendukung pembaca layar serta fokus keyboard jika platform menyediakan mekanismenya.
- Format nominal dan tanggal mengikuti locale perangkat, sementara penyimpanan tetap memakai format terstruktur.

## 12. Kriteria penerimaan MVP

1. Pengguna dapat menambah pemasukan dan pengeluaran valid.
2. Aplikasi menolak nominal nol atau negatif dan input wajib yang kosong.
3. Transaksi tetap tersedia setelah aplikasi ditutup dan dibuka kembali.
4. Pengguna dapat mengubah dan menghapus transaksi.
5. Ringkasan bulanan menghitung pemasukan, pengeluaran, dan selisih dengan benar.
6. Filter bulan menampilkan transaksi dan ringkasan periode yang dipilih.
7. Pengguna dapat menambah, mengubah, menghapus, dan melunasi tagihan.
8. Pengingat aktif dijadwalkan jika izin tersedia.
9. Mengubah atau menghapus tagihan memperbarui atau membatalkan jadwal pengingat terkait.
10. Tagihan berulang menghasilkan tanggal berikutnya sesuai aturan kalender.
11. Aplikasi tetap dapat mencatat dan membaca data saat perangkat offline.
12. Kegagalan database ditampilkan dengan pesan dan tidak menghapus data yang sudah tersimpan.
13. Hapus semua data meminta konfirmasi sebelum menghapus.

## 13. Fase pengembangan

### Fase 1: Fondasi lokal

- Inisialisasi aplikasi Flutter.
- Rancang model transaksi, kategori, tagihan, dan pengaturan.
- Buat penyimpanan SQLite dan migrasi skema awal.
- Implementasikan tambah, daftar, edit, dan hapus transaksi.
- Buat ringkasan bulanan dan validasi.

### Fase 2: Tagihan dan notifikasi

- Implementasikan siklus hidup tagihan.
- Implementasikan perhitungan pengulangan.
- Tambahkan izin dan penjadwalan notifikasi lokal.
- Uji pembatalan dan penjadwalan ulang notifikasi.

### Fase 3: Kualitas dan portofolio

- Uji alur kosong, berhasil, gagal, dan offline.
- Tambahkan data demo yang jelas ditandai sebagai data lokal contoh, jika dibutuhkan untuk demonstrasi.
- Tulis README proyek, instruksi menjalankan aplikasi, keputusan teknis, dan batasan MVP.
- Rekam demo alur tambah transaksi dan pengingat.

### Fase 4: Backend Go dan sinkronisasi, di luar MVP

- Buat Go REST API dan PostgreSQL.
- Tambahkan registrasi, login, dan kepemilikan data per pengguna.
- Tentukan kontrak API dan versi skema.
- Tambahkan antrean perubahan lokal dan status sync.
- Tangani retry, konflik perubahan, logout, dan pemulihan sesi.
- Uji sinkronisasi setelah perangkat offline dan online kembali.

Fase backend baru dimulai setelah fitur lokal stabil. Sinkronisasi tidak boleh menimpa perubahan lokal yang belum tersimpan di server.

## 14. Risiko dan keputusan terbuka

- Perilaku notifikasi berbeda antar versi Android dan iOS. Verifikasi pada perangkat atau emulator target sebelum menyatakan fitur selesai.
- Sistem operasi dapat menunda atau menahan notifikasi. Tampilkan keadaan izin secara jujur dan sediakan fallback daftar tagihan.
- Pengulangan bulanan dan tahunan memiliki kasus tanggal kalender khusus. Uji akhir bulan dan tahun kabisat.
- Restore atau reinstall aplikasi dapat menghilangkan data lokal. Backup dan pemulihan cloud di luar MVP.
- Mata uang aktif untuk seluruh aplikasi dipilih agar scope MVP terjaga. Multi-mata-uang per transaksi dapat ditambahkan bila ada kebutuhan nyata.
- Nama produk Catat Uang bersifat sementara dan dapat diganti.

## 15. Rencana pengujian

### Unit test

- Validasi transaksi dan nominal.
- Perhitungan ringkasan bulanan.
- Perhitungan tanggal pengulangan mingguan, bulanan, dan tahunan.
- Aturan akhir bulan dan tahun kabisat.
- Transisi status tagihan dan pembatalan pengingat.

### Integration test

- Simpan, baca, ubah, dan hapus setiap entitas SQLite.
- Pastikan ringkasan berubah setelah transaksi berubah.
- Pastikan operasi gagal tidak merusak data sebelumnya.

### Uji manual

- Penggunaan pertama tanpa data.
- Membuat transaksi saat mode pesawat aktif.
- Menutup dan membuka aplikasi kembali.
- Menolak izin notifikasi, lalu memakai daftar tagihan sebagai fallback.
- Mengubah jatuh tempo setelah notifikasi dijadwalkan.
- Melunasi dan menghapus tagihan berulang.
- Menghapus semua data dan memastikan aplikasi kembali ke keadaan kosong.

## 16. Definisi selesai

MVP selesai saat seluruh kriteria penerimaan lulus, alur transaksi dan tagihan berjalan tanpa jaringan, pengingat mengikuti izin sistem operasi, data bertahan setelah aplikasi dimulai ulang, dan instruksi menjalankan serta menguji aplikasi tersedia di dokumentasi proyek.
