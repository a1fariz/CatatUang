# Skenario demo Catat Uang

Panduan walkthrough langsung atau rekaman layar sekitar 2 menit. Dokumen ini adalah naskah demo; repo belum menyertakan video atau screenshot hasil rekaman aplikasi.

Gunakan instalasi khusus demo dengan data contoh, bukan ledger keuangan pribadi. Siapkan backend dan build dengan `API_BASE_URL` jika ingin menunjukkan akun/sinkronisasi. Jangan menghapus data atau memasang build di atas aplikasi berisi data pengguna demi merekam demo.

## Urutan rekaman

| Waktu | Tampilan dan tindakan | Narasi singkat |
| --- | --- | --- |
| 0:00–0:15 | Buka **Catatan**, tunjukkan ringkasan periode dan filter **Masuk/Keluar** | “Catat Uang menyimpan ledger di SQLite sehingga pencatatan tidak memerlukan akun atau koneksi.” |
| 0:15–0:35 | Tekan **Tambah transaksi**, isi pemasukan/pengeluaran contoh, lalu **Simpan transaksi** | “Nominal, kategori, tanggal, dan catatan disimpan di perangkat. Perubahan belum otomatis diunggah.” |
| 0:35–0:50 | Buka **Tagihan**, tunjukkan contoh tagihan berulang dan riwayat pembayaran yang telah disiapkan | “Tagihan memiliki jadwal dan history pembayaran tersendiri; pengingat memakai fasilitas lokal perangkat.” |
| 0:50–1:20 | Buka **Pengaturan → Akun**, lalu **Sinkronisasi transaksi**; tunjukkan penautan sebelum menekan **Sinkronkan sekarang** | “Akun bersifat opsional. Pengguna menyetujui penautan ledger dan memulai sinkronisasi secara manual. Login saja tidak mengunggah data.” |
| 1:20–1:35 | Buka **Sinkronisasi tagihan dan pembayaran**, tunjukkan penautan terpisah atau statusnya | “Transaksi dan tagihan mempunyai penautan serta antreannya masing-masing. Retry menggunakan identitas operasi dan versi yang diperiksa server.” |
| 1:35–1:50 | Buka **Backup file terenkripsi**; tunjukkan form ekspor tanpa menampilkan frasa sandi | “Backup file mencakup data lokal, tetapi tidak menyertakan token akun. Pemulihan membutuhkan database target kosong dan konfirmasi pengguna.” |
| 1:50–2:00 | Tampilkan diagram README dan tautan run CI pada browser | “Client Flutter/SQLite terhubung ke Go/PostgreSQL. Bukti tes dibedakan dari deployment production dan penerimaan perangkat nyata.” |

Jika server/akun belum disiapkan, rekam bagian offline dan diagram saja. Jelaskan bahwa sinkronisasi belum didemonstrasikan pada rekaman tersebut; jangan mengganti alurnya dengan mock yang tidak diberi label.

## Skenario teknis tambahan untuk interview

- **Persistensi offline:** tambahkan transaksi contoh, tutup aplikasi melalui alur perangkat biasa, lalu buka kembali dan periksa catatan yang sama.
- **Persetujuan penautan:** login dan lihat bahwa data belum diunggah; tinjau akun tujuan sebelum menautkan dan menjalankan sinkronisasi.
- **Konflik dua ledger:** gunakan dua lingkungan tes terpisah dan ikuti [panduan transaksi](../mobile/docs/transaction-sync.md). Sediakan waktu untuk membandingkan pilihan konflik; jangan mengklaim hasil yang tidak dijalankan.
- **Pembayaran dan retry:** jelaskan `Idempotency-Key`, pemeriksaan versi, transaksi database, dan constraint memakai [kontrak pembayaran](../backend/docs/api.md). Rujuk hasil tes jika tidak menunjukkan request langsung.
- **Backup/restore:** ikuti [panduan backup](../mobile/docs/external-backup.md) dengan ledger contoh dan target kosong. Jangan mengosongkan aplikasi pengguna untuk memenuhi syarat restore.

## Sebelum dibagikan

Pastikan video tidak menampilkan email pribadi, token sesi, isi `.env`, frasa sandi backup, atau catatan keuangan nyata. Bedakan jadwal pengingat yang terlihat dalam aplikasi dari bukti notifikasi OS benar-benar diterima. Cantumkan bahwa build demo adalah development dan rilis store belum tersedia.

Kembali ke [README](../README.md) · [Bukti pengujian](../VERIFICATION.md) · [Gerbang rilis](../RELEASE_READINESS.md)
