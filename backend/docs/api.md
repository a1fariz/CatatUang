# Memakai API akun dan keuangan

Jalankan migrasi sebelum API. Database lama mendapatkan tabel sesi/rate limit melalui `000002_sessions.sql`; `000001_initial.sql` tidak diubah. Kontrak lengkap: [OpenAPI](openapi.json). Regenerasi kontrak setelah mengedit sumber: `node scripts/openapi.mjs` dari folder backend.

## Akun dan sesi

Contoh PowerShell untuk server lokal:

```powershell
$apiBase = 'http://127.0.0.1:8080'
$credentials = @{
    email = 'saya@example.com'
    password = 'ganti-dengan-passphrase-unik'
} | ConvertTo-Json
$session = Invoke-RestMethod "$apiBase/v1/auth/register" -Method Post -ContentType application/json -Body $credentials
$headers = @{ Authorization = "Bearer $($session.access_token)" }
Invoke-RestMethod "$apiBase/v1/me" -Headers $headers
```

Ganti passphrase contoh sebelum digunakan. Password minimal 15 karakter Unicode, maksimal 128 byte UTF-8; spasi dipertahankan. Email dinormalisasi ke lowercase setelah trim dan harus berupa alamat ASCII tanpa display name. Hash password tidak pernah dikembalikan. Respons sesi berisi token, jenis `Bearer`, waktu kedaluwarsa, serta ID/email pengguna.

Untuk akun yang sudah ada, gunakan `POST /v1/auth/login` dengan body kredensial yang sama. Token berlaku 24 jam. Token tidak dikirim melalui URL dan hanya hash-nya disimpan di database. Flutter menyimpan token pada secure storage perangkat; panduan integrasinya ada di `../../mobile/docs/account.md`.

```powershell
Invoke-RestMethod "$apiBase/v1/auth/logout" -Method Post -Headers $headers
# Atau cabut seluruh sesi milik akun:
# Invoke-RestMethod "$apiBase/v1/auth/logout-all" -Method Post -Headers $headers
```

Sesi kedaluwarsa/dicabut menghasilkan 401. Tidak ada refresh token; lakukan login ulang. Belum ada endpoint verifikasi email, pemulihan lupa password, atau pengaturan akun.

`POST /v1/auth/change-password` menerima Bearer dan JSON `current_password`, `new_password`. Keduanya mengikuti batas panjang password; nilai baru harus berbeda. Respons 204 berarti hash berubah dan sesi lain dicabut secara atomik. Token pemanggil tetap berlaku sampai expiry semula. Kata sandi lama salah menghasilkan 422; sesi tidak valid menghasilkan 401; konflik perubahan bersamaan menghasilkan 409. Bucket rate limit khusus per IP/per akun membatasi 20 percobaan per 15 menit, dengan 429/Retry-After 900. Jangan retry otomatis setelah hasil jaringan yang belum pasti. Lihat [panduan Flutter](../../mobile/docs/password-change.md).

Login/register memiliki fixed window 15 menit dengan maksimum 20 percobaan untuk masing-masing IP koneksi dan email. Percobaan sukses tetap dihitung. 429 menyertakan `Retry-After: 900`. Jangan mengulang login otomatis tanpa jeda. `X-Forwarded-For` diabaikan; reverse proxy memerlukan rancangan trusted proxy sebelum melayani banyak pengguna.

## Transaksi

```powershell
$transactionInput = @{
    type = 'expense'
    amount_minor = 42000
    currency_code = 'IDR'
    category = 'Makan'
    occurred_on = '2026-10-25'
    note = 'Makan siang'
} | ConvertTo-Json
$transaction = Invoke-RestMethod "$apiBase/v1/transactions" -Method Post -Headers $headers -ContentType application/json -Body $transactionInput
Invoke-RestMethod "$apiBase/v1/transactions?from=2026-10-01&to=2026-11-01&type=expense&limit=50&offset=0" -Headers $headers
```

Contoh di atas memerlukan token yang masih aktif; bila logout telah dijalankan, login ulang dahulu.

- `amount_minor`: integer positif sampai 9007199254740991. IDR 42000 berarti Rp42.000; USD 1234 berarti $12,34. Jangan mengirim nominal floating point.
- `type`: `income` atau `expense`.
- Kategori pemasukan: `Gaji`, `Bonus`, `Lainnya`; pengeluaran: `Makan`, `Transportasi`, `Belanja`, `Tagihan`, `Lainnya`.
- Mata uang: IDR, USD, EUR, SGD, ditulis eksplisit per catatan. Integrasi dengan aturan satu mata uang aktif mobile belum tersedia.
- `occurred_on`: tanggal kalender 2000–2100, format `YYYY-MM-DD`; tidak bergeser mengikuti zona waktu.
- Catatan maksimal 200 karakter. Field pemilik, ID, versi, dan timestamp server tidak dapat ditulis lewat body.

Daftar mengembalikan `items`, `limit`, `offset`, `has_more`. Default limit 50, maksimal 100; offset maksimal 10000. Filter `from` inklusif, `to` eksklusif. Field query asing atau berulang ditolak. Offset pagination tidak menjamin snapshot ketika ada perubahan bersamaan dan bukan cursor sinkronisasi.

## Edit, hapus, dan konflik versi

GET/POST/PUT sumber daya mengembalikan `version` dan header ETag, misalnya `"1"`. Kirim ETag terakhir dalam `If-Match` untuk PUT/DELETE. PUT mengganti seluruh field yang dapat diedit; field opsional yang dihilangkan kembali menjadi nilai kosong/null.

```powershell
$changeHeaders = @{
    Authorization = $headers.Authorization
    'If-Match' = '"1"'
}
$updated = Invoke-RestMethod "$apiBase/v1/transactions/$($transaction.id)" -Method Put -Headers $changeHeaders -ContentType application/json -Body $transactionInput
$changeHeaders['If-Match'] = '"' + $updated.version + '"'
Invoke-RestMethod "$apiBase/v1/transactions/$($transaction.id)" -Method Delete -Headers $changeHeaders
```

Tanpa versi: 428. Format versi salah: 400. Versi sudah berubah: 409; muat ulang data dan minta pengguna meninjau perubahan sebelum mengirim ulang. Akses ke ID milik akun lain menghasilkan 404. Penghapusan bersifat soft delete dan mempertahankan tombstone.

POST tambah transaksi/tagihan belum memiliki idempotency key; retry buta dapat membuat dua catatan. Outbox dan idempotensi pembuatan data akan dirancang bersama protokol sync, bukan diasumsikan dari endpoint CRUD ini.

## Tagihan dan pembayaran

```powershell
$billInput = @{
    name = 'Internet'
    amount_minor = 125000
    currency_code = 'IDR'
    due_at = '2030-01-31T09:00:00+07:00'
    timezone = 'Asia/Jakarta'
    recurrence = 'monthly'
    recurrence_day = 31
    reminder_minutes = 60
} | ConvertTo-Json
$bill = Invoke-RestMethod "$apiBase/v1/bills" -Method Post -Headers $headers -ContentType application/json -Body $billInput
$paymentHeaders = @{
    Authorization = $headers.Authorization
    'If-Match' = '"1"'
    'Idempotency-Key' = [Guid]::NewGuid().ToString()
}
$paymentInput = @{ due_at = '2030-01-31T09:00:00+07:00' } | ConvertTo-Json
$result = Invoke-RestMethod "$apiBase/v1/bills/$($bill.id)/pay" -Method Post -Headers $paymentHeaders -ContentType application/json -Body $paymentInput
Invoke-RestMethod "$apiBase/v1/bills/$($bill.id)/payments" -Headers $headers
```

`due_at` wajib RFC3339 dengan presisi detik penuh dan tahun 2000–2100. `timezone` wajib nama IANA, bukan `Local`. Frekuensi: `once`, `weekly`, `monthly`, `yearly`. `recurrence_day` adalah anchor 1–31; untuk bulanan/tahunan tanggal lokal harus sesuai anchor atau hari terakhir bulan pendek. Pengingat dapat null atau offset 0–525600 menit. Backend menyimpan preferensi, tetapi tidak mengirim notifikasi perangkat.

Pembayaran meminta UUID lowercase sebagai `Idempotency-Key`, versi terakhir, dan tanggal kejadian yang dibayar pada `due_at`. Backend mengunci baris, menyimpan pembayaran, serta memperbarui status/tanggal tagihan dalam satu transaksi. Pembayaran belum otomatis membuat transaksi pengeluaran.

- Sekali bayar menjadi `paid` dan tidak dapat diedit lagi. Tagihan masih dapat dihapus.
- Tagihan berulang tetap aktif. Anchor 31 menghasilkan Januari 31 → Februari 28/29 → Maret 31. Pengulangan mingguan/bulanan/tahunan dihitung pada zona tagihan.
- Retry harus memakai key dan `due_at` yang sama. Respons mengembalikan pembayaran yang sama dengan `replayed: true` serta kondisi tagihan saat ini; versi lama hanya diabaikan untuk replay yang cocok.
- Key yang dipakai ulang untuk tagihan/kejadian berbeda ditolak. Key berbeda untuk kejadian yang sudah dibayar menghasilkan konflik.
- Dua pembayaran bersamaan untuk kejadian sama hanya mencatat satu pembayaran. Riwayat tetap tersimpan ketika tagihan di-soft-delete, tetapi endpoint riwayat tagihan yang dihapus tidak diekspos.

## Kontrak input dan error

Semua body wajib satu objek `application/json`, maksimal 16 KiB, dengan nama field persis seperti kontrak. Field duplikat, field asing, alias kapitalisasi, JSON beruntun, dan UTF-8 tidak valid ditolak. HEAD tersedia pada endpoint GET dan tidak mengembalikan body. Endpoint dikenal dengan metode salah mengembalikan 405 dan header Allow.

Error JSON berisi `code`, `message`, dan `request_id`; detail SQL/koneksi tidak dikirim. 401 berarti sesi/kredensial salah, 404 data tidak tersedia bagi pengguna tersebut, 409 konflik, 422 validasi, 429 rate limit, dan 503 timeout. Jangan menghapus data lokal ketika server gagal atau mengembalikan error.

Untuk operasional, jalankan `go run ./cmd/cleanup` secara berkala dengan role database yang memiliki izin penghapusan pada `sessions` dan `auth_rate_limits`. Perintah hanya menghapus data kedaluwarsa dan tidak memasang scheduler otomatis.
