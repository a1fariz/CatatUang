import 'package:flutter/material.dart';
import 'sync_controller.dart';

class SyncStatusNotice extends StatelessWidget {
  const SyncStatusNotice({super.key, this.controller, this.onTap});
  final TransactionSyncController? controller;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final sync = controller;
    if (sync == null) {
      return _notice(
        context,
        'Tersimpan di perangkat',
        'Bisa mencatat tanpa internet. Sinkronisasi akun belum tersedia pada build ini.',
        Icons.phone_android,
      );
    }
    return ListenableBuilder(
      listenable: Listenable.merge([sync, sync.account]),
      builder: (context, _) {
        if (!sync.statusLoaded) {
          return _notice(
            context,
            'Status sinkronisasi belum diketahui',
            'Catatan tetap lokal. Periksa status melalui Pengaturan.',
            Icons.info_outline,
          );
        }
        if (sync.busy) {
          return _notice(
            context,
            'Sinkronisasi sedang diproses',
            'Tunggu sampai proses selesai. Pencatatan tetap tersedia.',
            Icons.sync,
          );
        }
        if (sync.binding == null) {
          return _notice(
            context,
            'Tersimpan di perangkat',
            'Belum ditautkan. Masuk akun saja tidak mengirim catatan.',
            Icons.phone_android,
          );
        }
        if (sync.resetRequired || sync.issues.isNotEmpty) {
          return _notice(
            context,
            'Transaksi perlu ditinjau',
            'Buka Pengaturan untuk memeriksa konflik atau pemulihan.',
            Icons.warning_amber,
          );
        }
        if (!sync.ownerMatches ||
            !sync.account.hasSession ||
            !sync.account.verified) {
          return _notice(
            context,
            'Sinkronisasi menunggu akun',
            'Masuk dan periksa akun pemilik. Perubahan tetap tersimpan lokal.',
            Icons.account_circle_outlined,
          );
        }
        if (sync.pending > 0) {
          return _notice(
            context,
            '${sync.pending} perubahan transaksi menunggu',
            'Buka Pengaturan dan tekan Sinkronkan sekarang untuk mengirimnya.',
            Icons.cloud_upload_outlined,
          );
        }
        final last = sync.binding!.lastSuccess;
        return _notice(
          context,
          'Antrean transaksi kosong',
          last == null
              ? 'Belum ada sinkronisasi selesai. Jalankan manual di Pengaturan.'
              : 'Terakhir selesai: ${DateTime.parse(last).toLocal().toString().substring(0, 16)}. Data akun baru diperiksa saat sinkronisasi manual.',
          Icons.cloud_done_outlined,
        );
      },
    );
  }

  Widget _notice(
    BuildContext context,
    String title,
    String detail,
    IconData icon,
  ) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: ListTile(
      dense: true,
      leading: Icon(icon, size: 22),
      title: Text(title),
      subtitle: Text(
        '$detail\nStatus ini untuk transaksi; tagihan ditautkan terpisah.',
      ),
      onTap: onTap,
      trailing: onTap == null
          ? null
          : const Icon(Icons.chevron_right, size: 18),
    ),
  );
}
