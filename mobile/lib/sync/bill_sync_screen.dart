import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import '../auth/account_controller.dart';
import '../auth/auth_models.dart';
import '../backup/backup_screen.dart';
import '../reminder_service.dart';
import '../transaction_repository.dart';
import 'bill_sync_models.dart';
import 'sync_api.dart';
import 'sync_models.dart';

class BillSyncScreen extends StatefulWidget {
  const BillSyncScreen({
    super.key,
    required this.repository,
    required this.account,
    required this.onChanged,
    this.reminders,
  });
  final TransactionRepository repository;
  final AccountController account;
  final VoidCallback onChanged;
  final ReminderService? reminders;
  @override
  State<BillSyncScreen> createState() => _BillSyncScreenState();
}

class _BillSyncScreenState extends State<BillSyncScreen> {
  late final _gateway = HttpTransactionSyncGateway(
    baseUri: widget.account.serverUri,
  );
  SyncBinding? _binding;
  List<Map<String, Object?>> _issues = [];
  int _pending = 0;
  bool _busy = false;
  String? _message;
  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _gateway.close();
    super.dispose();
  }

  Future<void> _reload() async {
    final binding = await widget.repository.billSyncBinding();
    final pending = await widget.repository.billSyncPendingCount();
    final issues = await widget.repository.billSyncIssues();
    if (mounted) {
      setState(() {
        _binding = binding;
        _pending = pending;
        _issues = issues;
      });
    }
  }

  Future<T> _request<T>(
    SyncBinding binding,
    Future<T> Function(String) action,
  ) async {
    if (!mounted ||
        (await widget.repository.billSyncBinding())?.generation !=
            binding.generation) {
      throw const SyncFailure('Penautan tagihan berubah.');
    }
    return widget.account.authorized(
      userId: binding.userId,
      server: Uri.parse(binding.server),
      action: action,
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on SyncFailure catch (e) {
      _message = e.message;
    } on AuthFailure catch (e) {
      _message = e.message;
    } catch (_) {
      _message =
          'Sinkronisasi tagihan belum selesai. Data dan antrean lokal tetap tersimpan.';
    } finally {
      if (mounted) {
        await _reload();
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  Future<void> _link() async {
    final user = widget.account.user;
    if (user == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tautkan tagihan dan pembayaran?'),
        content: Text(
          'Tagihan beserta riwayat pembayaran lokal akan ditautkan ke ${user.email}. Saat disinkronkan, data akun digabungkan. Tagihan yang dimasukkan terpisah di dua perangkat dapat muncul ganda. Ekspor backup terlebih dahulu.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Tautkan tagihan'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      await widget.account.refresh();
      if (widget.account.user?.id != user.id || !widget.account.verified) {
        throw const SyncFailure('Akun berubah. Periksa akun terlebih dahulu.');
      }
      final zone = await FlutterTimezone.getLocalTimezone();
      await widget.repository.linkBillSync(
        server: widget.account.serverUri,
        userId: user.id,
        email: user.email,
        timezone: zone.identifier,
      );
      _message =
          'Tagihan ditautkan. Tekan Sinkronkan tagihan untuk melanjutkan.';
    });
  }

  Future<void> _push(SyncBinding b, SyncOperation op) async {
    try {
      final value = await _request(
        b,
        (token) => _gateway.requestJson(
          'POST',
          'v1/sync/bills',
          token,
          body: op.toJson(),
          dataset: b.datasetId,
        ),
      );
      await widget.repository.acknowledgeBill(
        b.generation,
        op,
        BillSyncRecord.fromJson(value),
      );
    } on SyncFailure catch (e) {
      if (e.code == 'sync_reset_required') rethrow;
      if (e.status == 409) {
        try {
          final value = await _request(
            b,
            (token) => _gateway.requestJson(
              'GET',
              'v1/sync/bills/${op.remoteId}',
              token,
              dataset: b.datasetId,
            ),
          );
          await widget.repository.rejectBill(
            b.generation,
            op,
            server: BillSyncRecord.fromJson(value),
          );
        } on SyncFailure catch (snapshot) {
          if (snapshot.status != 404) rethrow;
          await widget.repository.rejectBill(
            b.generation,
            op,
            error: 'Identitas tagihan ditolak; data lokal tetap tersimpan.',
          );
        }
      } else if (const [400, 413, 422].contains(e.status)) {
        await widget.repository.rejectBill(
          b.generation,
          op,
          error:
              'Tagihan ditolak. Periksa nama, tanggal, nominal, dan riwayat pembayaran.',
        );
      } else {
        rethrow;
      }
    }
  }

  Future<void> _pull(SyncBinding b) async {
    for (var i = 0; i < 200; i++) {
      final current = await widget.repository.billSyncBinding();
      if (current?.generation != b.generation) {
        throw const SyncFailure('Penautan berubah.');
      }
      final after = current!.cursor;
      // One aggregate per page bounds history-heavy responses to 1 MiB.
      final page = await _request(
        b,
        (token) => _gateway.requestJson(
          'GET',
          'v1/sync/bills?after=$after&limit=1',
          token,
          dataset: b.datasetId,
        ),
      );
      final records = _pageRecords(page, after);
      await widget.repository.applyBillPage(
        b.generation,
        after,
        records,
        page['cursor'] as int,
      );
      if (page['has_more'] == false) return;
    }
    throw const SyncFailure(
      'Sebagian tagihan diambil. Sinkronkan lagi untuk melanjutkan.',
    );
  }

  List<BillSyncRecord> _pageRecords(Map<String, dynamic> page, int after) {
    final items = page['items'], cursor = page['cursor'];
    if (items is! List ||
        items.length > 1 ||
        cursor is! int ||
        cursor < after ||
        cursor > 9007199254740991 ||
        page['has_more'] is! bool) {
      throw const FormatException('Invalid bill page');
    }
    var previous = after;
    final records = <BillSyncRecord>[];
    for (final item in items) {
      if (item is! Map ||
          item['sequence'] is! int ||
          (item['sequence'] as int) <= previous ||
          (item['sequence'] as int) > cursor) {
        throw const FormatException('Invalid bill sequence');
      }
      previous = item['sequence'] as int;
      records.add(
        BillSyncRecord.fromJson(
          Map<String, dynamic>.from(item['record'] as Map),
        ),
      );
    }
    if (page['has_more'] == true && (items.isEmpty || cursor != previous)) {
      throw const FormatException('Invalid continuation');
    }
    return records;
  }

  Future<void> _sync() async {
    final locale = Localizations.localeOf(context);
    await _run(() async {
      final before = await widget.repository.billSyncBinding();
      if (before == null) {
        throw const SyncFailure('Tautkan tagihan terlebih dahulu.');
      }
      await widget.account.refresh();
      final dataset = await _request(
        before,
        (token) => _gateway.datasetId(token),
      );
      await widget.repository.pinBillDataset(before.generation, dataset);
      final b = (await widget.repository.billSyncBinding())!;
      var sent = 0;
      while (sent < 100) {
        final op = await widget.repository.nextBillOperation(
          b.generation,
          inflightOnly: true,
        );
        if (op == null) break;
        await _push(b, op);
        sent++;
      }
      if (sent == 100) {
        throw const SyncFailure('Sebagian antrean diproses. Sinkronkan lagi.');
      }
      await _pull(b);
      while (sent < 100) {
        final op = await widget.repository.nextBillOperation(b.generation);
        if (op == null) break;
        await _push(b, op);
        sent++;
      }
      await _pull(b);
      _message =
          'Sinkronisasi tagihan selesai. Periksa antrean dan konflik di bawah.';
    });
    widget.onChanged();
    try {
      await (widget.reminders ?? ReminderService()).reconcile(
        await widget.repository.listBills(),
        settings: await widget.repository.getSettings(),
        locale: locale,
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'Data tersimpan; pengingat perlu diperiksa kembali.',
        );
      }
    }
  }

  Future<void> _reconcileReminders() async {
    if (!mounted) return;
    final locale = Localizations.localeOf(context);
    try {
      await (widget.reminders ?? ReminderService()).reconcile(
        await widget.repository.listBills(),
        settings: await widget.repository.getSettings(),
        locale: locale,
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'Data tersimpan; pengingat perlu diperiksa kembali.',
        );
      }
    }
  }

  Future<void> _recover() async {
    await _run(() async {
      final b = await widget.repository.billSyncBinding();
      if (b == null) throw const SyncFailure('Tautkan tagihan dahulu.');
      await widget.account.refresh();
      final fingerprint = jsonEncode(
        await widget.repository.billRecoverySnapshot(),
      );
      final dataset = await _request(b, (token) => _gateway.datasetId(token));
      final records = <String, BillSyncRecord>{};
      var cursor = 0, complete = false;
      for (var i = 0; i < 2000; i++) {
        final page = await _request(
          b,
          (token) => _gateway.requestJson(
            'GET',
            'v1/sync/bills?after=$cursor&limit=1',
            token,
            dataset: dataset,
          ),
        );
        for (final record in _pageRecords(page, cursor)) {
          records[record.id] = record;
        }
        cursor = page['cursor'] as int;
        if (page['has_more'] == false) {
          complete = true;
          break;
        }
      }
      if (!complete) {
        throw const SyncFailure(
          'Snapshot pemulihan terlalu besar. Data lokal tetap disimpan.',
        );
      }
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('Tinjau pemulihan tagihan'),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Tagihan dengan ID sama memakai versi akun di bawah. Tagihan yang hanya ada di perangkat dipertahankan dan diantrikan kembali. Antrean lama untuk tagihan akun diganti. Salinan kondisi lokal disimpan sebelum perubahan dan ikut dalam backup file. Ekspor backup terlebih dahulu jika perlu.',
              ),
              for (final record in records.values)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    '${record.json['name']} · ${record.json['amount_minor']} ${record.currency}\n${record.deleted ? 'Dihapus' : record.json['due_at']} · ${record.payments.length} pembayaran\n${record.id}',
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Gunakan versi akun yang ditinjau'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      if (await _request(b, (token) => _gateway.datasetId(token)) != dataset) {
        throw const SyncFailure(
          'Dataset berubah saat ditinjau. Ulangi pemulihan.',
        );
      }
      await widget.repository.reconcileBillDataset(
        b.generation,
        dataset,
        fingerprint,
        records.values.toList(),
      );
      widget.onChanged();
      _message =
          'Pemulihan tagihan diterapkan. Sinkronkan untuk mengirim tagihan lokal yang dipertahankan.';
    });
    await _reconcileReminders();
  }

  Future<void> _resolve(Map<String, Object?> issue) async {
    final raw = issue['conflict_json'];
    if (raw == null) return;
    final record = BillSyncRecord.fromJson(
      jsonDecode(raw as String) as Map<String, dynamic>,
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Gunakan versi akun?'),
        content: Text(
          '${record.json['name']} · ${record.json['amount_minor']} ${record.currency}\n${record.deleted ? 'Dihapus di akun' : record.json['due_at']}\n${record.payments.length} pembayaran\n\nVersi perangkat dan antrean tagihan ini akan diganti. Ekspor backup dahulu jika ingin mempertahankannya. Pembayaran dari dua perangkat tidak digabungkan otomatis.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Pertahankan lokal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Gunakan versi akun'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run(() async {
        await widget.repository.resolveBill(
          _binding!.generation,
          record.id,
          useServer: true,
        );
        widget.onChanged();
      });
      await _reconcileReminders();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Sinkronisasi tagihan')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Tagihan dan riwayat pembayaran memakai penautan serta antrean tersendiri. Transaksi tetap disinkronkan dari menu transaksi.',
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => Navigator.push<bool>(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ExternalBackupScreen(repository: widget.repository),
                    ),
                  ),
            child: const Text('Backup file terenkripsi'),
          ),
          if (_binding == null)
            FilledButton(
              onPressed: _busy || widget.account.user == null ? null : _link,
              child: const Text('Tautkan tagihan'),
            )
          else ...[
            Text(
              'Akun: ${_binding!.email}\nAntrean: $_pending\nKonflik/ditolak: ${_issues.length}',
            ),
            FilledButton(
              onPressed: _busy ? null : _sync,
              child: const Text('Sinkronkan tagihan'),
            ),
            TextButton(
              onPressed: _busy ? null : _recover,
              child: const Text('Tinjau pemulihan dataset tagihan'),
            ),
          ],
          if (_busy) const LinearProgressIndicator(),
          if (_message != null) Text(_message!),
          for (final issue in _issues)
            ListTile(
              title: Text(
                issue['error'] as String? ??
                    'Tagihan berubah di akun dan perangkat',
              ),
              subtitle: Text(issue['remote_id'] as String),
              trailing: issue['conflict_json'] == null
                  ? null
                  : TextButton(
                      onPressed: _busy ? null : () => _resolve(issue),
                      child: const Text('Tinjau'),
                    ),
            ),
        ],
      ),
    ),
  );
}
