import 'package:flutter/material.dart';

import 'bill.dart';
import 'sync/bill_sync_models.dart';
import 'money_format.dart';
import 'reminder_service.dart';
import 'settings.dart';
import 'transaction_repository.dart';

enum BillFormResult { saved, savedWithoutReminder }

class BillsScreen extends StatefulWidget {
  const BillsScreen({
    super.key,
    required this.repository,
    this.settings = const AppSettings(),
    this.reminders,
  });

  final TransactionRepository repository;
  final AppSettings settings;
  final ReminderService? reminders;

  @override
  State<BillsScreen> createState() => _BillsScreenState();
}

class _BillsScreenState extends State<BillsScreen> {
  ReminderService get _reminders => widget.reminders ?? _defaultReminders;
  final _defaultReminders = ReminderService();
  List<Bill> _bills = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bills = await widget.repository.listBills();
      if (!mounted) return;
      setState(() {
        _bills = bills;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Tagihan gagal dimuat. Coba lagi.';
        _loading = false;
      });
    }
  }

  Future<void> _openForm([Bill? bill]) async {
    final result = await showModalBottomSheet<BillFormResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => BillForm(
        bill: bill,
        repository: widget.repository,
        reminders: _reminders,
        currencyCode: widget.settings.currencyCode,
        notificationsEnabled: widget.settings.notificationsEnabled,
      ),
    );
    if (result != null) {
      await _load();
      if (result == BillFormResult.savedWithoutReminder && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Izin pengingat tidak tersedia. Tagihan tetap tersimpan tanpa notifikasi.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _pay(Bill bill) async {
    final locale = Localizations.localeOf(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tandai lunas?'),
        content: Text('Pembayaran ${bill.name} akan dicatat hari ini.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sudah lunas'),
          ),
        ],
      ),
    );
    if (confirmed != true || bill.id == null) return;
    try {
      await widget.repository.payBill(bill, DateTime.now());
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pembayaran gagal dicatat. Coba lagi.')),
      );
      return;
    }
    var reminderFailed = false;
    try {
      await _reminders.cancel(bill.id!);
      if (widget.settings.notificationsEnabled &&
          bill.recurrence != BillRecurrence.once &&
          bill.reminderMinutes != null) {
        final updated = bill.copyWith(
          dueAt: bill.timezone != null
              ? nextZonedBillDue(bill)
              : nextDueDate(
                  bill.dueAt,
                  bill.recurrence,
                  recurrenceDay: bill.recurrenceDay,
                ),
        );
        await _reminders.schedule(
          updated,
          currencyCode: widget.settings.currencyCode,
          locale: locale,
        );
      }
    } catch (_) {
      reminderFailed = true;
    }
    await _load();
    if (reminderFailed && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Lunas tercatat, tetapi pengingat berikutnya gagal dijadwalkan.',
          ),
        ),
      );
    }
  }

  Future<void> _delete(Bill bill) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus tagihan?'),
        content: const Text('Tagihan dan pengingatnya akan dihapus.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (confirmed != true || bill.id == null) return;
    try {
      await widget.repository.deleteBill(bill.id!);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tagihan gagal dihapus. Coba lagi.')),
      );
      return;
    }
    var reminderFailed = false;
    try {
      await _reminders.cancel(bill.id!);
    } catch (_) {
      reminderFailed = true;
    }
    await _load();
    if (reminderFailed && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Tagihan terhapus, tetapi pengingat perangkat gagal dibatalkan.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tagihan')),
      body: _content(),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add-bill',
        onPressed: () => _openForm(),
        icon: const Icon(Icons.add),
        label: const Text('Tambah tagihan'),
      ),
    );
  }

  Widget _content() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Coba lagi')),
          ],
        ),
      );
    }
    if (_bills.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Belum ada tagihan. Tambahkan tagihan untuk mencatat jatuh tempo dan pengingat.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      itemCount: _bills.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 64),
      itemBuilder: (context, index) {
        final bill = _bills[index];
        final daysLate = billDaysLate(bill, DateTime.now());
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 6,
          ),
          leading: CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
            child: Icon(
              bill.recurrence == BillRecurrence.once
                  ? Icons.receipt_long
                  : Icons.autorenew,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          title: Text(bill.name),
          subtitle: Text(
            '${_billDueLabel(billCalendarDate(bill.dueAt, bill.timezone), daysLate)} · ${_recurrenceLabel(bill.recurrence)}'
            '${bill.timezone == null ? '' : ' · ${bill.timezone}'}'
            '${bill.reminderMinutes == null || !widget.settings.notificationsEnabled ? '' : ' · Pengingat aktif'}',
          ),
          isThreeLine: true,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                formatMoneyAmount(
                  bill.amount,
                  widget.settings.currencyCode,
                  Localizations.localeOf(context),
                ),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              PopupMenuButton<String>(
                tooltip: 'Aksi tagihan',
                onSelected: (action) {
                  if (action == 'paid') _pay(bill);
                  if (action == 'edit') _openForm(bill);
                  if (action == 'delete') _delete(bill);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'paid', child: Text('Tandai lunas')),
                  PopupMenuItem(value: 'edit', child: Text('Ubah')),
                  PopupMenuItem(value: 'delete', child: Text('Hapus')),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class BillForm extends StatefulWidget {
  const BillForm({
    super.key,
    required this.repository,
    required this.reminders,
    required this.currencyCode,
    required this.notificationsEnabled,
    this.bill,
  });

  final TransactionRepository repository;
  final ReminderService reminders;
  final String currencyCode;
  final bool notificationsEnabled;
  final Bill? bill;

  @override
  State<BillForm> createState() => _BillFormState();
}

class _BillFormState extends State<BillForm> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _amountController = TextEditingController();
  late BillRecurrence _recurrence;
  late DateTime _dueAt;
  late int _recurrenceDay;
  int? _reminderMinutes;
  bool _saving = false;
  bool _zoneLoaded = false;
  String? _timezone;
  String? _error;

  @override
  void initState() {
    super.initState();
    final bill = widget.bill;
    _nameController.text = bill?.name ?? '';
    _amountController.text = bill?.amount.toString() ?? '';
    _recurrence = bill?.recurrence ?? BillRecurrence.once;
    _dueAt =
        bill?.dueAt ??
        DateTime(
          DateTime.now().year,
          DateTime.now().month,
          DateTime.now().day,
          9,
        );
    _recurrenceDay = bill?.recurrenceDay ?? _dueAt.day;
    _reminderMinutes = bill?.reminderMinutes;
    _timezone = bill?.timezone;
    _zoneLoaded = bill != null;
    if (bill == null) {
      _loadDefaultZone();
    }
  }

  Future<void> _loadDefaultZone() async {
    try {
      final zone = await widget.repository.defaultBillTimezone();
      if (!mounted) return;
      final date = billCalendarDate(DateTime.now(), zone);
      setState(() {
        _timezone = zone;
        _dueAt = billDueOnDate(date, zone);
        _recurrenceDay = date.day;
        _zoneLoaded = true;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Zona tagihan gagal dibaca. Kembali lalu coba lagi.',
        );
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.bill == null ? 'Tagihan baru' : 'Ubah tagihan',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _nameController,
                maxLength: 80,
                decoration: const InputDecoration(
                  labelText: 'Nama tagihan',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value ?? '').trim().isEmpty
                    ? 'Masukkan nama tagihan.'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _amountController,
                keyboardType: TextInputType.numberWithOptions(
                  decimal: currencyFractionDigits(widget.currencyCode) > 0,
                ),
                decoration: InputDecoration(
                  labelText: 'Nominal ${widget.currencyCode}',
                  prefixText: '${currencySymbol(widget.currencyCode)} ',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  final amount = parseMoneyAmount(
                    value ?? '',
                    widget.currencyCode,
                    Localizations.localeOf(context),
                  );
                  if (amount == null || amount <= 0) {
                    return 'Masukkan nominal lebih dari 0.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<BillRecurrence>(
                initialValue: _recurrence,
                decoration: const InputDecoration(
                  labelText: 'Frekuensi',
                  border: OutlineInputBorder(),
                ),
                items: BillRecurrence.values
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text(_recurrenceLabel(value)),
                      ),
                    )
                    .toList(),
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _recurrence = value!),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _saving || !_zoneLoaded ? null : _pickDate,
                icon: const Icon(Icons.calendar_today),
                label: Text(
                  'Jatuh tempo: ${_dateLabel(billCalendarDate(_dueAt, _timezone))}${_timezone == null ? '' : ' ($_timezone)'}',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int?>(
                initialValue: _reminderMinutes,
                decoration: InputDecoration(
                  labelText: widget.notificationsEnabled
                      ? 'Pengingat'
                      : 'Pengingat dimatikan di Pengaturan',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem<int?>(value: null, child: Text('Tidak ada')),
                  DropdownMenuItem<int?>(
                    value: 1440,
                    child: Text('Sehari sebelumnya'),
                  ),
                  DropdownMenuItem<int?>(
                    value: 60,
                    child: Text('Sejam sebelumnya'),
                  ),
                ],
                onChanged: _saving || !widget.notificationsEnabled
                    ? null
                    : (value) => setState(() => _reminderMinutes = value),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 16),
              if (!_zoneLoaded && _error == null)
                const LinearProgressIndicator(),
              FilledButton(
                onPressed: _saving || !_zoneLoaded ? null : _save,
                child: Text(_saving ? 'Menyimpan...' : 'Simpan tagihan'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: billCalendarDate(_dueAt, _timezone),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date != null) {
      setState(() {
        _dueAt = billDueOnDate(date, _timezone);
        _recurrenceDay = date.day;
      });
    }
  }

  Future<void> _save() async {
    if (!_zoneLoaded) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final locale = Localizations.localeOf(context);
    final requestedReminder = widget.notificationsEnabled
        ? _reminderMinutes
        : null;
    var permissionGranted = requestedReminder == null;
    if (requestedReminder != null) {
      try {
        permissionGranted = await widget.reminders.requestPermission();
      } catch (_) {
        permissionGranted = false;
      }
    }
    final bill = Bill(
      id: widget.bill?.id,
      name: _nameController.text.trim(),
      amount: parseMoneyAmount(
        _amountController.text,
        widget.currencyCode,
        locale,
      )!,
      dueAt: _dueAt,
      recurrence: _recurrence,
      recurrenceDay: _recurrenceDay,
      reminderMinutes: permissionGranted ? requestedReminder : null,
      status: BillStatus.active,
      timezone: _timezone,
    );
    try {
      final id = await widget.repository.saveBill(bill);
      final savedBill = Bill(
        id: bill.id ?? id,
        name: bill.name,
        amount: bill.amount,
        dueAt: bill.dueAt,
        recurrence: bill.recurrence,
        recurrenceDay: bill.recurrenceDay,
        reminderMinutes: bill.reminderMinutes,
        status: bill.status,
        timezone: bill.timezone,
      );
      var reminderSaved = permissionGranted;
      try {
        await widget.reminders.cancel(savedBill.id!);
        if (savedBill.reminderMinutes != null) {
          await widget.reminders.schedule(
            savedBill,
            currencyCode: widget.currencyCode,
            locale: locale,
          );
        }
      } catch (_) {
        reminderSaved = false;
        if (savedBill.reminderMinutes != null) {
          await widget.repository.saveBill(
            savedBill.copyWith(clearReminder: true),
          );
        }
      }
      if (mounted) {
        Navigator.pop(
          context,
          reminderSaved
              ? BillFormResult.saved
              : BillFormResult.savedWithoutReminder,
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Tagihan gagal disimpan. Coba lagi.';
      });
    }
  }
}

String _billDueLabel(DateTime dueAt, int daysLate) {
  if (daysLate > 0) return 'Terlambat $daysLate hari';
  if (daysLate == 0) return 'Jatuh tempo hari ini';
  return 'Jatuh tempo ${_dateLabel(dueAt)}';
}

String _recurrenceLabel(BillRecurrence recurrence) => switch (recurrence) {
  BillRecurrence.once => 'Sekali',
  BillRecurrence.weekly => 'Mingguan',
  BillRecurrence.monthly => 'Bulanan',
  BillRecurrence.yearly => 'Tahunan',
};

String _dateLabel(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
