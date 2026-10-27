import 'dart:async';

import 'package:flutter/material.dart';

import 'auth/account_controller.dart';
import 'auth/auth_api.dart';
import 'auth/session_store.dart';

import 'bills_screen.dart';
import 'money_format.dart';
import 'reminder_service.dart';
import 'settings.dart';
import 'settings_screen.dart';
import 'transaction.dart';
import 'transaction_repository.dart';
import 'sync/sync_api.dart';
import 'sync/sync_controller.dart';
import 'sync/sync_status_notice.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(CatatUangApp());
}

class CatatUangApp extends StatefulWidget {
  CatatUangApp({
    super.key,
    TransactionRepository? repository,
    this.demo = false,
  }) : repository = repository ?? TransactionRepository();

  final TransactionRepository repository;
  final bool demo;

  @override
  State<CatatUangApp> createState() => _CatatUangAppState();
}

class _CatatUangAppState extends State<CatatUangApp> {
  AppSettings _settings = const AppSettings();
  AccountController? _account;
  TransactionSyncController? _sync;

  @override
  void initState() {
    super.initState();
    try {
      final server = configuredApiUri(
        const String.fromEnvironment('API_BASE_URL'),
      );
      if (server != null) {
        _account = AccountController(
          gateway: HttpAuthGateway(baseUri: server),
          store: SecureSessionStore(server: server),
        );
        _sync = TransactionSyncController(
          repository: widget.repository,
          account: _account!,
          gateway: HttpTransactionSyncGateway(baseUri: server),
        );
      }
    } on FormatException {
      // Invalid account configuration must not block local bookkeeping.
      debugPrint(
        'Konfigurasi API_BASE_URL tidak valid; fitur akun dinonaktifkan.',
      );
    }
    _loadSettings();
  }

  @override
  void dispose() {
    _sync?.dispose();
    _account?.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    try {
      final value = await widget.repository.getSettings();
      if (mounted) setState(() => _settings = value);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final dark = _settings.darkMode;
    final surface = dark ? const Color(0xFF201A17) : const Color(0xFFFFFAF5);
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xFF8C4A32),
      brightness: dark ? Brightness.dark : Brightness.light,
      surface: surface,
    );
    return MaterialApp(
      title: 'Catat Uang',
      builder: (context, child) => widget.demo
          ? Column(
              children: [
                const Material(
                  color: Color(0xFFFFE6B5),
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      child: Text(
                        'DEMO • Data contoh • Tersimpan di perangkat',
                        style: TextStyle(
                          color: Color(0xFF513500),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(child: child!),
              ],
            )
          : child!,
      theme: ThemeData(
        colorScheme: colors,
        scaffoldBackgroundColor: surface,
        appBarTheme: AppBarTheme(
          backgroundColor: surface,
          surfaceTintColor: Colors.transparent,
        ),
        useMaterial3: true,
      ),
      home: HomeScreen(
        repository: widget.repository,
        account: _account,
        sync: _sync,
        onSettingsChanged: (value) => setState(() => _settings = value),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.repository,
    required this.onSettingsChanged,
    this.reminders,
    this.account,
    this.sync,
  });

  final TransactionRepository repository;
  final ValueChanged<AppSettings> onSettingsChanged;
  final ReminderService? reminders;
  final AccountController? account;
  final TransactionSyncController? sync;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _selectedIndex = 0;
  int _dataRevision = 0;
  bool _started = false;
  bool _restoring = false;
  final _defaultReminders = ReminderService();
  ReminderService get _reminders => widget.reminders ?? _defaultReminders;
  AppSettings _settings = const AppSettings();
  int _syncRevision = 0;
  void _syncChanged() {
    final revision = widget.sync?.dataRevision ?? 0;
    if (mounted && revision != _syncRevision) {
      setState(() {
        _syncRevision = revision;
        _dataRevision++;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.sync?.addListener(_syncChanged);
    final sync = widget.sync;
    if (sync != null) unawaited(sync.reload());
    final account = widget.account;
    if (account != null) unawaited(account.initialize());
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sync != widget.sync) {
      oldWidget.sync?.removeListener(_syncChanged);
      widget.sync?.addListener(_syncChanged);
      final sync = widget.sync;
      if (sync != null) unawaited(sync.reload());
    }
    final account = widget.account;
    if (account != null && oldWidget.account != account) {
      unawaited(account.initialize());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _restoreReminders();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _restoreReminders();
      final account = widget.account;
      if (account != null) unawaited(account.refresh());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.sync?.removeListener(_syncChanged);
    super.dispose();
  }

  Future<void> _restoreReminders() async {
    if (_restoring) return;
    _restoring = true;
    final locale = Localizations.localeOf(context);
    try {
      final settings = await widget.repository.getSettings();
      if (!mounted) return;
      _updateSettings(settings);
      final bills = await widget.repository.listBills();
      if (!mounted) return;
      await _reminders.reconcile(bills, settings: settings, locale: locale);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Pengingat gagal dipulihkan. Coba lagi.'),
          action: SnackBarAction(
            label: 'Coba lagi',
            onPressed: _restoreReminders,
          ),
        ),
      );
    } finally {
      _restoring = false;
    }
  }

  void _updateSettings(AppSettings value) {
    setState(() => _settings = value);
    widget.onSettingsChanged(value);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: _selectedIndex,
      children: [
        TransactionsScreen(
          key: ValueKey('transactions-$_dataRevision'),
          repository: widget.repository,
          settings: _settings,
          sync: widget.sync,
          onOpenSync: () => setState(() => _selectedIndex = 2),
        ),
        BillsScreen(
          key: ValueKey('bills-$_dataRevision'),
          repository: widget.repository,
          settings: _settings,
          reminders: _reminders,
        ),
        SettingsScreen(
          repository: widget.repository,
          account: widget.account,
          sync: widget.sync,
          settings: _settings,
          onChanged: _updateSettings,
          reminders: _reminders,
          onDataCleared: () => setState(() => _dataRevision++),
        ),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _selectedIndex,
      onDestinationSelected: (value) {
        setState(() => _selectedIndex = value);
        final sync = widget.sync;
        if (value == 2 && sync != null) unawaited(sync.reload());
      },
      destinations: const [
        NavigationDestination(icon: Icon(Icons.receipt_long), label: 'Catatan'),
        NavigationDestination(icon: Icon(Icons.event_note), label: 'Tagihan'),
        NavigationDestination(icon: Icon(Icons.tune), label: 'Pengaturan'),
      ],
    ),
  );
}

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({
    super.key,
    this.repository,
    this.settings = const AppSettings(),
    this.sync,
    this.onOpenSync,
  });

  final TransactionRepository? repository;
  final AppSettings settings;
  final TransactionSyncController? sync;
  final VoidCallback? onOpenSync;

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  late final TransactionRepository _repository;
  late DateTime _periodStart;
  List<MoneyTransaction> _transactions = [];
  String _filter = 'all';
  bool _loading = true;
  String? _error;
  bool _firstEntry = false;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? TransactionRepository();
    _periodStart = periodStartFor(
      DateTime.now(),
      widget.settings.monthStartDay,
    );
    _load();
  }

  @override
  void didUpdateWidget(covariant TransactionsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.monthStartDay != widget.settings.monthStartDay) {
      _periodStart = periodStartFor(
        DateTime.now(),
        widget.settings.monthStartDay,
      );
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final transactions = await _repository.list(periodStart: _periodStart);
      final firstEntry = !await _repository.hasEntries();
      await widget.sync?.reload();
      if (!mounted) return;
      setState(() {
        _transactions = transactions;
        _firstEntry = firstEntry;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Transaksi gagal dimuat. Coba lagi.';
        _loading = false;
      });
    }
  }

  Future<void> _openForm([MoneyTransaction? transaction]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => TransactionForm(
        transaction: transaction,
        repository: _repository,
        currencyCode: widget.settings.currencyCode,
      ),
    );
    if (saved == true) await _load();
  }

  Future<void> _delete(MoneyTransaction transaction) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus transaksi?'),
        content: const Text(
          'Transaksi ini akan dihapus dari perangkat. Jika catatan terhubung ke akun, penghapusan ikut dikirim pada sinkronisasi berikutnya.',
        ),
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
    if (confirmed != true || transaction.id == null) return;
    try {
      await _repository.delete(transaction.id!);
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Transaksi gagal dihapus. Coba lagi.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = _filter == 'all'
        ? _transactions
        : _transactions.where((item) => item.type.name == _filter).toList();
    final income = _transactions
        .where((item) => item.type == TransactionType.income)
        .fold<int>(0, (sum, item) => sum + item.amount);
    final expense = _transactions
        .where((item) => item.type == TransactionType.expense)
        .fold<int>(0, (sum, item) => sum + item.amount);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Catat Uang'),
        actions: [
          IconButton(
            tooltip: 'Periode sebelumnya',
            onPressed: () => _changePeriod(-1),
            icon: const Icon(Icons.chevron_left),
          ),
          Center(child: Text(_periodLabel(_periodStart))),
          IconButton(
            tooltip: 'Periode berikutnya',
            onPressed: () => _changePeriod(1),
            icon: const Icon(Icons.chevron_right),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            SyncStatusNotice(controller: widget.sync, onTap: widget.onOpenSync),
            _Summary(
              income: income,
              expense: expense,
              currencyCode: widget.settings.currencyCode,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'all', label: Text('Semua')),
                  ButtonSegment(value: 'income', label: Text('Masuk')),
                  ButtonSegment(value: 'expense', label: Text('Keluar')),
                ],
                selected: {_filter},
                onSelectionChanged: (selected) =>
                    setState(() => _filter = selected.first),
              ),
            ),
            Expanded(child: _content(visible)),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add-transaction',
        onPressed: () => _openForm(),
        icon: const Icon(Icons.add),
        label: const Text('Tambah transaksi'),
      ),
    );
  }

  Widget _content(List<MoneyTransaction> visible) {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Memuat transaksi...'),
          ],
        ),
      );
    }
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
    if (visible.isEmpty) {
      final hasAny = _transactions.isNotEmpty;
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 100),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                hasAny ? Icons.filter_list_off : Icons.receipt_long,
                size: 42,
              ),
              const SizedBox(height: 12),
              Text(
                hasAny
                    ? 'Tidak ada transaksi di filter ini.'
                    : _firstEntry
                    ? 'Mulai dari satu catatan'
                    : 'Belum ada transaksi periode ini.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (!hasAny) ...[
                const SizedBox(height: 6),
                Text(
                  _firstEntry
                      ? '1. Pilih pemasukan atau pengeluaran.\n2. Isi nominal, kategori, dan tanggal.\n3. Simpan. Catatan tetap ada saat aplikasi ditutup.'
                      : 'Pilih periode lain atau tambahkan transaksi baru.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Bisa digunakan tanpa internet dan tanpa akun.',
                  textAlign: TextAlign.center,
                ),
                if (_firstEntry) ...[
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => _openForm(),
                    icon: const Icon(Icons.edit_note),
                    label: const Text('Catat transaksi pertama'),
                  ),
                ],
              ],
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      itemCount: visible.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
      itemBuilder: (context, index) {
        final transaction = visible[index];
        final isIncome = transaction.type == TransactionType.income;
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 4,
          ),
          leading: CircleAvatar(
            backgroundColor: isIncome
                ? Theme.of(context).colorScheme.tertiaryContainer
                : Theme.of(context).colorScheme.errorContainer,
            foregroundColor: isIncome
                ? Theme.of(context).colorScheme.onTertiaryContainer
                : Theme.of(context).colorScheme.onErrorContainer,
            child: Icon(isIncome ? Icons.south_west : Icons.north_east),
          ),
          title: Text(transaction.category),
          subtitle: Text(
            [
              _dateLabel(transaction.occurredAt),
              if (transaction.note.isNotEmpty) transaction.note,
            ].join(' · '),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${isIncome ? '+' : '−'}${formatMoneyAmount(transaction.amount, widget.settings.currencyCode, Localizations.localeOf(context))}',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: isIncome
                      ? Theme.of(context).colorScheme.tertiary
                      : null,
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Aksi transaksi',
                onSelected: (action) {
                  if (action == 'edit') _openForm(transaction);
                  if (action == 'delete') _delete(transaction);
                },
                itemBuilder: (_) => const [
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

  void _changePeriod(int offset) {
    setState(
      () => _periodStart = DateTime(
        _periodStart.year,
        _periodStart.month + offset,
        _periodStart.day,
      ),
    );
    _load();
  }
}

class _Summary extends StatelessWidget {
  const _Summary({
    required this.income,
    required this.expense,
    required this.currencyCode,
  });

  final int income;
  final int expense;
  final String currencyCode;

  @override
  Widget build(BuildContext context) {
    final balance = income - expense;
    final locale = Localizations.localeOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Selisih periode',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                '${balance < 0 ? '−' : ''}${formatMoneyAmount(balance.abs(), currencyCode, locale)}',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: balance < 0
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _SummaryValue(
                      label: 'Masuk',
                      amount: income,
                      currencyCode: currencyCode,
                    ),
                  ),
                  Expanded(
                    child: _SummaryValue(
                      label: 'Keluar',
                      amount: expense,
                      currencyCode: currencyCode,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SummaryValue extends StatelessWidget {
  const _SummaryValue({
    required this.label,
    required this.amount,
    required this.currencyCode,
  });

  final String label;
  final int amount;
  final String currencyCode;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 3),
      Text(
        formatMoneyAmount(
          amount,
          currencyCode,
          Localizations.localeOf(context),
        ),
        style: Theme.of(context).textTheme.titleMedium,
      ),
    ],
  );
}

class TransactionForm extends StatefulWidget {
  const TransactionForm({
    super.key,
    this.transaction,
    this.repository,
    this.currencyCode = 'IDR',
  });

  final MoneyTransaction? transaction;
  final TransactionRepository? repository;
  final String currencyCode;

  @override
  State<TransactionForm> createState() => _TransactionFormState();
}

class _TransactionFormState extends State<TransactionForm> {
  static const _incomeCategories = ['Gaji', 'Bonus', 'Lainnya'];
  static const _expenseCategories = [
    'Makan',
    'Transportasi',
    'Belanja',
    'Tagihan',
    'Lainnya',
  ];
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _noteController = TextEditingController();
  late final TransactionRepository _repository =
      widget.repository ?? TransactionRepository();
  late TransactionType _type;
  late String _category;
  late DateTime _date;
  bool _saving = false;
  String? _saveError;

  List<String> get _categories =>
      _type == TransactionType.income ? _incomeCategories : _expenseCategories;

  @override
  void initState() {
    super.initState();
    final transaction = widget.transaction;
    _type = transaction?.type ?? TransactionType.expense;
    _category = transaction?.category ?? _categories.first;
    _date = transaction?.occurredAt ?? DateTime.now();
    if (transaction != null) {
      _amountController.text = transaction.amount.toString();
      _noteController.text = transaction.note;
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
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
              widget.transaction == null ? 'Transaksi baru' : 'Ubah transaksi',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 20),
            SegmentedButton<TransactionType>(
              segments: const [
                ButtonSegment(
                  value: TransactionType.expense,
                  label: Text('Keluar'),
                ),
                ButtonSegment(
                  value: TransactionType.income,
                  label: Text('Masuk'),
                ),
              ],
              selected: {_type},
              onSelectionChanged: _saving
                  ? null
                  : (selection) => setState(() {
                      _type = selection.first;
                      _category = _categories.first;
                    }),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _amountController,
              keyboardType: TextInputType.numberWithOptions(
                decimal: currencyFractionDigits(widget.currencyCode) > 0,
              ),
              decoration: InputDecoration(
                labelText: 'Nominal ${widget.currencyCode}',
                prefixText: '${currencySymbol(widget.currencyCode)} ',
                border: const OutlineInputBorder(),
              ),
              validator: (value) =>
                  parseMoneyAmount(
                        value ?? '',
                        widget.currencyCode,
                        Localizations.localeOf(context),
                      ) ==
                      null
                  ? 'Masukkan nominal valid lebih dari 0.'
                  : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _category,
              decoration: const InputDecoration(
                labelText: 'Kategori',
                border: OutlineInputBorder(),
              ),
              items: _categories
                  .map(
                    (category) => DropdownMenuItem(
                      value: category,
                      child: Text(category),
                    ),
                  )
                  .toList(),
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _category = value!),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _saving ? null : _pickDate,
              icon: const Icon(Icons.calendar_today),
              label: Text('Tanggal: ${_dateLabel(_date)}'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _noteController,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: 'Catatan (opsional)',
                border: OutlineInputBorder(),
              ),
            ),
            if (_saveError != null) ...[
              Text(
                _saveError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Menyimpan...' : 'Simpan transaksi'),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date != null) setState(() => _date = date);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final locale = Localizations.localeOf(context);
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final amount = parseMoneyAmount(
        _amountController.text,
        widget.currencyCode,
        locale,
      )!;
      await _repository.save(
        MoneyTransaction(
          id: widget.transaction?.id,
          type: _type,
          amount: amount,
          category: _category,
          occurredAt: DateTime(_date.year, _date.month, _date.day),
          note: _noteController.text.trim(),
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = 'Transaksi gagal disimpan. Coba lagi.';
      });
    }
  }
}

String _periodLabel(DateTime start) {
  if (start.day == 1) return '${_monthName(start.month)} ${start.year}';
  final end = DateTime(start.year, start.month + 1, start.day - 1);
  return '${start.day} ${_monthName(start.month)} - ${end.day} ${_monthName(end.month)} ${end.year}';
}

String _monthName(int month) => const [
  'Januari',
  'Februari',
  'Maret',
  'April',
  'Mei',
  'Juni',
  'Juli',
  'Agustus',
  'September',
  'Oktober',
  'November',
  'Desember',
][month - 1];

String _dateLabel(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
