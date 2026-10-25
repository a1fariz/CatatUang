# Sinkronisasi transaksi: kontrak backend

Backend menyediakan protokol transaksi dua arah. Flutter menggunakan SQLite lokal dengan [sinkronisasi manual opsional](../../mobile/docs/transaction-sync.md) yang memanggil endpoint ini setelah penautan. Tagihan, pembayaran, dan pengaturan tidak termasuk protokol ini.

## Endpoint

Semua endpoint memakai sesi Bearer dan hanya mengakses data pemilik sesi. Format lengkap ada di [OpenAPI](openapi.json).

Sejak protokol 0.4, klien membaca `GET /v1/sync/state` dan menyimpan `dataset_id` sebelum sinkronisasi pertama. Semua endpoint transaksi sync wajib membawa header `X-Sync-Dataset` yang sudah dipin. Header hilang menghasilkan 428 `sync_dataset_required`; identitas berbeda menghasilkan 409 `sync_reset_required`, termasuk replay receipt lama. API CRUD biasa tidak memakai header ini.

| Metode | Path | Hasil |
|---|---|---|
| GET | `/v1/sync/transactions?after=0&limit=50` | Halaman perubahan, `cursor`, `has_more` |
| POST | `/v1/sync/transactions` | Mutasi atomik beserta receipt idempotensi |
| GET | `/v1/sync/transactions/{id}` | Snapshot terkini, termasuk transaksi terhapus |

GET juga mendukung HEAD. Parameter tidak dikenal/duplikat ditolak; batas halaman 1–100. POST menerima satu mutasi, bukan batch, dengan batas body 16 KiB dan JSON ketat hingga payload bersarang.

Contoh pembuatan (UUID dibuat dan disimpan oleh klien sebelum pengiriman):

```json
{
  "operation_id": "144bf8f0-727e-4a1b-82d0-fbdbf652e622",
  "id": "b995d137-a956-4bd8-87a0-74f25ad83882",
  "base_version": 0,
  "deleted": false,
  "payload": {
    "type": "expense",
    "amount_minor": 42000,
    "currency_code": "IDR",
    "category": "Makan",
    "occurred_on": "2026-10-25",
    "note": "Makan siang"
  }
}
```

`base_version: 0` berarti membuat record. Pembaruan dan pemulihan record terhapus memerlukan versi server terkini beserta payload. Penghapusan memerlukan versi positif, `deleted: true`, dan payload null/tidak dikirim. Versi dibandingkan di bawah row lock. Ketidakcocokan menghasilkan 409 tanpa mengubah record. Konflik tidak ditimpa otomatis.

`operation_id` berlaku per akun. Retry harus mengirim isi semantik yang sama, termasuk ID record dan versi dasar. Receipt dan perubahan disimpan dalam satu transaksi PostgreSQL. Retry yang cocok mengembalikan **snapshot hasil operasi semula**, sekalipun record kini sudah berubah. Klien harus tetap melakukan pull; respons retry bukan bukti bahwa snapshot itu masih terkini. Menggunakan ID operasi lama untuk isi berbeda menghasilkan 409.

## Feed dan cursor

Feed menyimpan snapshot setiap insert/update, termasuk perubahan melalui API CRUD biasa dan soft delete. `sequence` meningkat per akun. `cursor` adalah posisi halaman yang sudah dikirim. Mulai dari 0, simpan data halaman dan cursor secara atomik di klien, lalu lanjutkan selama `has_more` bernilai true. Halaman kosong tetap mengembalikan cursor yang sah. Snapshot lama tidak boleh menimpa versi lokal yang lebih baru.

Clock menggunakan row yang dikunci sampai commit, sehingga penulis berikutnya untuk akun yang sama tidak dapat melewati perubahan yang belum commit. Query pull memakai snapshot repeatable read agar clock dan isi halaman konsisten. Rollback membatalkan kenaikan clock beserta perubahan. Akun berbeda memiliki clock terpisah.

Cursor lebih besar daripada clock server menghasilkan 409 dengan kode `sync_reset_required`. Jangan mengulang dari 0 secara diam-diam; rekonsiliasi harus menjaga perubahan lokal yang belum dikirim. Cursor dan antrean klien harus terikat ke URL server serta identitas akun, bukan dipindahkan saat ganti akun.

## Migrasi dan operasi

Migrasi tambahan `000003_transaction_sync.sql` membuat baseline dari transaksi yang sudah ada, termasuk tombstone, tanpa mengubah isi transaksi. Migrasi mengunci penulisan tabel selama backfill; lakukan pada jendela pemeliharaan untuk tabel besar. Migrasi lama tidak diubah.

Log perubahan, tombstone, dan receipt belum dipangkas otomatis. Penyimpanan bertambah mengikuti jumlah perubahan. Penghapusan fisik record biasa atau pemangkasan log akan melanggar kontrak ini; belum ada kebijakan retensi/kompaksi. Penghapusan akun melalui administrasi database membersihkan metadata melalui foreign key cascade.

Migrasi `000004_sync_dataset.sql` menambahkan identitas dataset yang persisten. Identitas tidak berubah saat restart/deploy biasa. Setelah restore/replacement database, operator wajib merotasi identitas sebelum membuka akses klien; lihat [prosedur restore](restore-sync.md). UUID yang ikut dipulihkan dari backup tidak otomatis berubah, sehingga melewatkan rotasi tetap berbahaya.

Push memeriksa identitas dalam transaksi dan memegang shared row lock sampai commit; rotasi menunggu push yang sudah diterima selesai. Pull dan pembacaan snapshot memeriksa identitas serta data dalam snapshot repeatable read yang sama. Klien tidak boleh mengubah pin/cursor atau membuang antrean otomatis saat menerima reset.

## Klien Flutter dan kelanjutan

- Flutter sudah memakai persetujuan penautan, UUID record tetap, outbox persisten atomik, retry operasi tetap, dan aplikasi halaman/cursor atomik dengan penjagaan generasi lokal.
- UI menyediakan pilihan konflik dan menolak halaman mata uang yang berbeda; sinkronisasi dijalankan manual, bukan saat login/logout.
- Dua file SQLite dengan dua sesi akun telah diuji terhadap backend nyata. Pengujian dua perangkat Android/native masih perlu dilakukan secara terisolasi.
- Pembayaran tagihan membutuhkan protokol tersendiri agar pembayaran offline tidak tercatat dua kali.

Verifikasi lokal meliputi PostgreSQL nyata: retry paralel, konflik dua penulis, isolasi akun, pagination, tombstone/pemulihan, penangkapan CRUD, rollback, JSON bersarang, serta backfill migrasi. Tidak ada instalasi Android atau perubahan database keuangan pengguna dalam tahap ini.
