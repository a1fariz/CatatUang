import 'package:flutter/material.dart';

import 'auth/account_controller.dart';
import 'auth/account_screen.dart';

import 'reminder_service.dart';
import 'settings.dart';
import 'transaction_repository.dart';
import 'sync/sync_controller.dart';
import 'sync/sync_card.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.repository,
    required this.settings,
    required this.onChanged,
    this.onDataCleared,
    this.reminders,
    this.account,
    this.sync,
  });

  final TransactionRepository repository;
  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;
  final VoidCallback? onDataCleared;
  final ReminderService? reminders;
  final AccountController? account;
  final TransactionSyncController? sync;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _defaultReminders = ReminderService();
  ReminderService get _reminders => widget.reminders ?? _defaultReminders;
  late AppSettings _settings = widget.settings;
  bool _busy = false;
  String? _error;

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings != widget.settings) _settings = widget.settings;
  }

  Future<void> _save(AppSettings settings) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.saveSettings(settings);
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _busy = false;
      });
      widget.onChanged(settings);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Pengaturan gagal disimpan. Coba lagi.';
      });
    }
  }

  Future<void> _toggleNotifications(bool enabled) async {
    final locale = Localizations.localeOf(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (enabled && !await _reminders.requestPermission()) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error =
              'Izin notifikasi belum aktif. Nyalakan izin di pengaturan perangkat.';
        });
        return;
      }
      final bills = await widget.repository.listBills();
      if (enabled) {
        for (final bill in bills) {
          if (bill.reminderMinutes != null) {
            await _reminders.schedule(
              bill,
              currencyCode: _settings.currencyCode,
              locale: locale,
            );
          }
        }
      } else {
        await _reminders.cancelAll();
      }
      await widget.repository.saveSettings(
        _settings.copyWith(notificationsEnabled: enabled),
      );
      if (!mounted) return;
      final updated = _settings.copyWith(notificationsEnabled: enabled);
      setState(() {
        _settings = updated;
        _busy = false;
      });
      widget.onChanged(updated);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Pengingat gagal diperbarui. Coba lagi.';
      });
    }
  }

  Future<void> _changeCurrency(String? currencyCode) async {
    if (currencyCode == null || currencyCode == _settings.currencyCode) return;
    try {
      if (await widget.repository.hasEntries()) {
        if (!mounted) return;
        setState(
          () => _error =
              'Hapus semua transaksi dan tagihan sebelum mengganti mata uang.',
        );
        return;
      }
      if (await widget.repository.syncBinding() != null) {
        if (!mounted) return;
        setState(
          () => _error = 'Mata uang tetap selama catatan terhubung ke akun.',
        );
        return;
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Data gagal diperiksa. Coba lagi.');
      return;
    }
    await _save(_settings.copyWith(currencyCode: currencyCode));
  }

  Future<void> _clearData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus semua data?'),
        content: const Text(
          'Transaksi, tagihan, riwayat pembayaran, pengaturan, antrean sinkronisasi, dan cadangan transaksi lokal akan dihapus. Penautan catatan dilepas. Akun tetap masuk; data di server tidak dihapus. Operasi yang sedang dikirim mungkin sudah diterima server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hapus semua'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.clearAllData();
      await widget.sync?.reload();
      try {
        await _reminders.cancelAll();
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Data terhapus, tetapi notifikasi perangkat gagal dibatalkan.',
              ),
            ),
          );
        }
      }
      if (!mounted) return;
      const defaults = AppSettings();
      setState(() {
        _settings = defaults;
        _busy = false;
      });
      widget.onChanged(defaults);
      widget.onDataCleared?.call();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Data gagal dihapus. Coba lagi.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pengaturan')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _accountEntry(),
          if (widget.sync case final sync?)
            TransactionSyncCard(controller: sync),
          const SizedBox(height: 20),
          DropdownButtonFormField<String>(
            initialValue: _settings.currencyCode,
            decoration: const InputDecoration(
              labelText: 'Mata uang',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'IDR', child: Text('Rupiah (IDR)')),
              DropdownMenuItem(value: 'USD', child: Text('US Dollar (USD)')),
              DropdownMenuItem(value: 'EUR', child: Text('Euro (EUR)')),
              DropdownMenuItem(
                value: 'SGD',
                child: Text('Singapore Dollar (SGD)'),
              ),
            ],
            onChanged: _busy ? null : _changeCurrency,
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<int>(
            initialValue: _settings.monthStartDay,
            decoration: const InputDecoration(
              labelText: 'Awal periode bulanan',
              border: OutlineInputBorder(),
            ),
            items: List.generate(
              28,
              (index) => DropdownMenuItem(
                value: index + 1,
                child: Text('Tanggal ${index + 1}'),
              ),
            ),
            onChanged: _busy
                ? null
                : (day) {
                    if (day != null) {
                      _save(_settings.copyWith(monthStartDay: day));
                    }
                  },
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Tema gelap'),
            subtitle: const Text(
              'Gunakan tampilan gelap untuk kondisi minim cahaya.',
            ),
            value: _settings.darkMode,
            onChanged: _busy
                ? null
                : (enabled) => _save(_settings.copyWith(darkMode: enabled)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Pengingat tagihan'),
            subtitle: const Text(
              'Izinkan notifikasi lokal untuk tagihan terjadwal.',
            ),
            value: _settings.notificationsEnabled,
            onChanged: _busy ? null : _toggleNotifications,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 28),
          OutlinedButton.icon(
            onPressed: _busy ? null : _clearData,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Hapus semua data lokal'),
          ),
          const SizedBox(height: 12),
          const Text(
            'Catatan tersimpan di perangkat. Sinkronisasi transaksi bersifat opsional melalui akun.',
          ),
        ],
      ),
    );
  }

  Widget _accountEntry() {
    final account = widget.account;
    if (account == null) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.account_circle_outlined),
          title: Text('Akun'),
          subtitle: Text(
            'Akun belum diaktifkan pada versi ini. Pencatatan tetap dapat digunakan.',
          ),
        ),
      );
    }
    return ListenableBuilder(
      listenable: account,
      builder: (context, _) => Card(
        child: ListTile(
          leading: const Icon(Icons.account_circle_outlined),
          title: const Text('Akun'),
          subtitle: Text(
            account.busy
                ? 'Memeriksa akun…'
                : account.user?.email ?? 'Masuk atau buat akun',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AccountScreen(controller: account),
            ),
          ),
        ),
      ),
    );
  }
}
