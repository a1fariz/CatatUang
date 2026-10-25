# Identitas dataset dan pemulihan sinkronisasi

Cursor hanya bermakna dalam satu dataset. Backup yang dipulihkan dapat memiliki angka cursor sama dengan perangkat, tetapi berisi perubahan berbeda. Identitas dataset membedakan riwayat itu **jika operator merotasinya setelah restore**.

## Pemeriksaan tanpa perubahan

Dengan `DATABASE_URL` untuk database yang dimaksud dan skema terbaru:

```powershell
./scripts/go.ps1 run ./cmd/sync-dataset status
```

Perintah menampilkan UUID identitas dataset tanpa URL database/kredensial. Identitas tersimpan pada tabel singleton `sync_dataset`, bukan dibuat ulang saat startup API.

## Setelah restore atau replacement

1. Putuskan akses klien untuk pemeliharaan dan hentikan seluruh penulis. Simpan backup server dan salinan database lokal perangkat terdampak. Jangan hapus outbox perangkat.
2. Pulihkan database melalui prosedur PostgreSQL organisasi yang sudah diuji. Pastikan target database benar; dokumen ini tidak menjalankan restore/penghapusan otomatis.
3. Jalankan migrasi terbaru dan verifikasi skema database hasil restore.
4. **Sebelum menerima klien**, rotasi identitas:

```powershell
./scripts/go.ps1 run ./cmd/sync-dataset rotate-after-restore
./scripts/go.ps1 run ./cmd/sync-dataset status
```

5. Verifikasi UUID berbeda dari dataset sebelum restore, lalu buka API. Perangkat dengan pin lama dihentikan melalui `sync_reset_required`; data dan antrean lokal dipertahankan.
6. Rekonsiliasi melalui [layar peninjauan Flutter](../../mobile/docs/recovery.md): bandingkan setiap perbedaan, pilih data perangkat/akun, lalu konfirmasi. Aplikasi menyimpan cadangan sebelum menerapkan pilihan dan menyiapkan antrean baru dengan UUID record yang tetap. Jangan melewati peninjauan dengan mengubah pin, membuang outbox, atau menghapus semua data; perubahan lokal dapat hilang atau transaksi tergandakan.

Rotasi tidak mengubah transaksi, clock, log, receipt, pengguna, atau sesi. Rotasi tidak memperbaiki backup maupun menggabungkan data perangkat. Tidak perlu rotasi pada restart/deploy biasa. Rotasi tanpa restore tetap menghentikan semua klien tertaut, sehingga command ini hanya untuk operator pemulihan.

Binary container tersedia di `/app/sync-dataset`; gunakan environment database yang benar untuk command administrasi. Role runtime memerlukan SELECT dan hak row locking pada tabel ini. Untuk pemisahan role, `SELECT` bersama `UPDATE (id)` memungkinkan `FOR SHARE` tanpa UPDATE pada kolom `dataset_id`; role migrasi/restore mengelola rotasi. Pemisahan role deployment belum diotomatisasi proyek.

## Kompatibilitas

Klien baru menyimpan pin pada SQLite versi 8. Klien lama tanpa header ditolak dengan 428 dan harus diperbarui. Ledger baru yang belum pernah mengirim/menerima perubahan dapat memin identitas pertama. Ledger versi 7 dengan cursor, versi remote, atau operasi inflight tidak boleh menebak identitas awal: sinkronisasi dihentikan sambil mempertahankan data untuk rekonsiliasi.

Uji lokal mencakup migrasi PostgreSQL/SQLite, pin lama dengan cursor sama, penolakan sebelum receipt replay, perlindungan antrean, command status/rotasi, serta peninjauan/penerapan pilihan dari dua SQLite terhadap backend nyata. Ini belum merupakan uji restore backup production; dataset besar atau mata uang yang tidak didukung tetap memerlukan pemeriksaan operator.
