import 'package:flutter/material.dart';

import '../money_format.dart';
import 'sync_controller.dart';
import 'sync_models.dart';

class TransactionSyncCard extends StatelessWidget {
  const TransactionSyncCard({super.key, required this.controller});
  final TransactionSyncController controller;

  Future<void> _link(BuildContext context) async {
    final email = controller.account.user?.email;
    final userId = controller.account.user?.id;
    if (email == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Tautkan transaksi ke akun?'),
        content: Text(
          'Catatan perangkat ini akan ditautkan ke $email. Saat Anda menekan Sinkronkan sekarang, transaksi lokal dikirim dan transaksi akun digabungkan ke perangkat. Catatan serupa yang dimasukkan terpisah dapat muncul ganda. Tagihan dan pembayaran tetap lokal. Penautan tetap tersimpan saat keluar akun.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Tautkan transaksi'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.link(expectedUserId: userId);
  }

  Future<void> _conflict(BuildContext context, SyncIssue issue) async {
    final server = issue.server;
    final binding = controller.binding;
    if (server == null || binding == null) return;
    String describe(
      bool deleted,
      int? amount,
      String? category,
      String? date,
      String? note,
    ) {
      if (deleted) return 'Dihapus';
      return '${formatMoneyAmount(amount!, binding.currency, Localizations.localeOf(context))} · $category\n$date${note == null || note.isEmpty ? '' : '\n$note'}';
    }

    final local = issue.local;
    final choice = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pilih catatan yang dipertahankan'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Di perangkat',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                describe(
                  local == null,
                  local?.amount,
                  local?.category,
                  local?.occurredAt.toIso8601String().substring(0, 10),
                  local?.note,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Di akun',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                describe(
                  server.deleted,
                  server.json['amount_minor'] as int,
                  server.json['category'] as String,
                  server.json['occurred_on'] as String,
                  server.json['note'] as String,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Pilihan perangkat dikirim pada sinkronisasi berikutnya. Jika akun berubah lagi, konflik diperiksa kembali.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Gunakan data akun'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Pertahankan perangkat'),
          ),
        ],
      ),
    );
    if (choice != null) {
      await controller.resolve(issue.remoteId, keepLocal: choice);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, controller.account]),
    builder: (context, _) {
      final binding = controller.binding;
      final account = controller.account;
      final available =
          !controller.busy &&
          !account.busy &&
          account.hasSession &&
          account.verified &&
          controller.ownerMatches;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Sinkronisasi transaksi',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                binding == null
                    ? 'Opsional. Transaksi tetap lokal sampai Anda menautkan catatan dan menjalankan sinkronisasi.'
                    : 'Terhubung ke ${binding.email}\n${controller.pending} perubahan menunggu dikirim.',
              ),
              if (binding != null && !controller.ownerMatches)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Masuk dengan akun pemilik catatan untuk melanjutkan. Antrean tidak dikirim ke akun lain.',
                  ),
                ),
              if (binding == null && !account.hasSession)
                const Text('Masuk ke akun terlebih dahulu.'),
              if (binding != null && binding.lastSuccess != null)
                Text(
                  'Terakhir selesai: ${DateTime.parse(binding.lastSuccess!).toLocal().toString().substring(0, 16)}',
                ),
              const SizedBox(height: 8),
              if (binding == null)
                OutlinedButton(
                  onPressed: available ? () => _link(context) : null,
                  child: const Text('Tautkan transaksi'),
                )
              else
                FilledButton.icon(
                  onPressed: available ? controller.synchronize : null,
                  icon: const Icon(Icons.sync),
                  label: Text(
                    controller.busy ? 'Menyinkronkan…' : 'Sinkronkan sekarang',
                  ),
                ),
              if (account.hasSession && !account.verified)
                TextButton(
                  onPressed: account.busy ? null : account.refresh,
                  child: const Text('Periksa akun'),
                ),
              if (controller.message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(controller.message!),
                ),
              for (final issue in controller.issues)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.warning_amber),
                  title: Text(issue.message),
                  subtitle: issue.local == null
                      ? const Text('Catatan dihapus dari perangkat.')
                      : Text('${issue.local!.category} · ${issue.local!.note}'),
                  trailing: issue.server == null
                      ? null
                      : const Icon(Icons.chevron_right),
                  onTap: issue.server != null && available
                      ? () => _conflict(context, issue)
                      : null,
                ),
              const Text(
                'Dijalankan manual. Tagihan, pembayaran, dan pengaturan belum disinkronkan.',
              ),
            ],
          ),
        ),
      );
    },
  );
}
