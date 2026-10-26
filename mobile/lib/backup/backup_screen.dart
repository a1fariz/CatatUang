import 'dart:convert';
import 'package:flutter/material.dart';
import '../transaction_repository.dart';
import 'backup_codec.dart';
import 'backup_files.dart';

class ExternalBackupScreen extends StatefulWidget {
  const ExternalBackupScreen({super.key, required this.repository, this.files});
  final TransactionRepository repository;
  final BackupFiles? files;
  @override
  State<ExternalBackupScreen> createState() => _ExternalBackupScreenState();
}

class _ExternalBackupScreenState extends State<ExternalBackupScreen> {
  final _password = TextEditingController(), _confirm = TextEditingController();
  bool _busy = false;
  String? _message;
  BackupFiles get _files => widget.files ?? NativeBackupFiles();
  Future<void> _run(bool exporting) async {
    if (_busy) {
      return;
    }
    if (exporting && _password.text != _confirm.text) {
      setState(() => _message = 'Konfirmasi frasa sandi belum sama.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    final password = _password.text;
    try {
      if (exporting) {
        final snapshot = await widget.repository.backupSnapshot();
        final bytes = await sealBackup(jsonEncode(snapshot), password);
        final saved = await _files.save(bytes);
        if (mounted) {
          setState(
            () => _message = saved
                ? 'Backup terenkripsi disimpan. Simpan frasa sandi terpisah; tanpa frasa sandi file tidak dapat dibuka.'
                : 'Penyimpanan dibatalkan.',
          );
        }
      } else {
        final bytes = await _files.read();
        if (bytes == null) {
          return;
        }
        final backup = await openBackup(bytes, password);
        final tables = backup['tables'];
        if (tables is! Map) {
          throw const BackupFailure('Isi backup tidak valid.');
        }
        if (!mounted) {
          return;
        }
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Pulihkan backup file?'),
            content: Text(
              '${(tables['transactions'] as List?)?.length ?? 0} transaksi, ${(tables['bills'] as List?)?.length ?? 0} tagihan, ${(tables['bill_payments'] as List?)?.length ?? 0} pembayaran.\nPemulihan hanya berlaku pada data lokal kosong. Pengaturan dan penautan dari backup ikut dipulihkan; token login tidak dipulihkan. Data server tidak diubah.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Batal'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Pulihkan file'),
              ),
            ],
          ),
        );
        if (confirmed != true) {
          return;
        }
        await widget.repository.restoreExternalBackup(backup);
        if (mounted) {
          Navigator.pop(context, true);
        }
      }
    } on BackupFailure catch (e) {
      if (mounted) {
        setState(() => _message = e.message);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'Operasi backup belum selesai. File atau data lokal tidak dapat diproses.',
        );
      }
    } finally {
      _password.clear();
      _confirm.clear();
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Backup file terenkripsi')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Ekspor seluruh transaksi, tagihan, pembayaran, pengaturan, serta antrean dan cadangan lokal. Token dan kata sandi akun tidak disertakan. Pilih lokasi di luar penyimpanan aplikasi agar file tetap ada jika aplikasi dihapus.',
          ),
          const SizedBox(height: 16),
          const Text(
            'Gunakan frasa sandi backup tersendiri, minimal 15 karakter. Frasa sandi tidak disimpan oleh aplikasi dan tidak dapat direset. Pemulihan file hanya ke data lokal kosong.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _password,
            enabled: !_busy,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Frasa sandi backup',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _confirm,
            enabled: !_busy,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Ulangi frasa sandi untuk ekspor',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          if (_busy)
            const LinearProgressIndicator(semanticsLabel: 'Memproses backup'),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_message!),
            ),
          FilledButton(
            onPressed: _busy ? null : () => _run(true),
            child: const Text('Ekspor backup terenkripsi'),
          ),
          OutlinedButton(
            onPressed: _busy ? null : () => _run(false),
            child: const Text('Pulihkan dari file'),
          ),
        ],
      ),
    ),
  );
}
