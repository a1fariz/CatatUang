import 'package:flutter/material.dart';

import '../transaction.dart';
import '../money_format.dart';
import 'sync_controller.dart';
import 'sync_recovery.dart';

class SyncRecoveryScreen extends StatefulWidget {
  const SyncRecoveryScreen({
    super.key,
    required this.controller,
    required this.plan,
  });
  final TransactionSyncController controller;
  final RecoveryPlan plan;
  @override
  State<SyncRecoveryScreen> createState() => _SyncRecoveryScreenState();
}

class _SyncRecoveryScreenState extends State<SyncRecoveryScreen> {
  String describe(MoneyTransaction? value) => value == null
      ? 'Tidak ada / dihapus'
      : '${formatMoneyAmount(value.amount, widget.plan.binding.currency, Localizations.localeOf(context))} · ${value.category}\n${value.occurredAt.toIso8601String().substring(0, 10)}${value.note.isEmpty ? '' : '\n${value.note}'}';
  Future<void> _apply() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Terapkan pilihan pemulihan?'),
        content: const Text(
          'Daftar transaksi lokal akan mengikuti pilihan Anda. Kondisi transaksi dan antrean saat ini disimpan sebagai cadangan di perangkat. Pilihan perangkat belum dikirim sampai sinkronisasi dijalankan lagi. Tagihan dan pembayaran tetap tersimpan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Terapkan pilihan'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final applied = await widget.controller.applyRecovery(widget.plan);
    if (!mounted) return;
    if (applied) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Tinjau pemulihan transaksi')),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: widget.plan.items.length + 2,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                'Akun ${widget.plan.binding.email}\n${widget.plan.items.length} catatan, ${widget.plan.unresolved} perbedaan belum dipilih. Catatan akun yang belum ada di perangkat dipilih untuk diambil. Bandingkan semua pilihan sebelum menerapkan.',
              ),
            );
          }
          if (index == widget.plan.items.length + 1) {
            return Column(
              children: [
                if (widget.controller.message != null)
                  Text(widget.controller.message!),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed:
                      widget.plan.unresolved == 0 && !widget.controller.busy
                      ? _apply
                      : null,
                  child: const Text('Terapkan pemulihan'),
                ),
              ],
            );
          }
          final item = widget.plan.items[index - 1];
          final remote = item.server;
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Catatan $index',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Di perangkat',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(describe(item.local)),
                  const SizedBox(height: 12),
                  const Text(
                    'Di akun',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    describe(
                      remote == null || remote.deleted
                          ? null
                          : remote.local(null),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('Pertahankan perangkat'),
                        selected: item.keepLocal == true,
                        onSelected: widget.controller.busy
                            ? null
                            : (_) => setState(() => item.keepLocal = true),
                      ),
                      ChoiceChip(
                        label: const Text('Gunakan data akun'),
                        selected: item.keepLocal == false,
                        onSelected: widget.controller.busy
                            ? null
                            : (_) => setState(() => item.keepLocal = false),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}
