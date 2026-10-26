import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:catat_uang/bill.dart';
import 'package:catat_uang/bills_screen.dart';
import 'package:catat_uang/main.dart';
import 'package:catat_uang/reminder_service.dart';
import 'package:catat_uang/settings_screen.dart';
import 'package:catat_uang/settings.dart';
import 'package:catat_uang/transaction.dart';
import 'package:catat_uang/transaction_repository.dart';
import 'package:catat_uang/sync/bill_sync_models.dart';

class _NoopReminderService extends ReminderService {
  final scheduled = <Bill>[];
  @override
  Future<List<int>> pendingIds() async => [];
  @override
  Future<void> cancelAll() async {}

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> schedule(
    Bill bill, {
    required String currencyCode,
    required Locale locale,
  }) async {
    scheduled.add(bill);
  }
}

void main() {
  setUpAll(sqfliteFfiInit);
  testWidgets(
    'new linked bill form preserves ledger wall clock in a different timezone',
    (tester) async {
      final repository = TransactionRepository(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: inMemoryDatabasePath,
      );
      addTearDown(repository.close);
      await repository.linkBillSync(
        server: Uri.parse('https://api.example.com/'),
        userId: '11111111-1111-4111-8111-111111111111',
        email: 'test@example.com',
        timezone: 'America/New_York',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: BillsScreen(
            repository: repository,
            reminders: _NoopReminderService(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Tambah tagihan'));
      await tester.pumpAndSettle();
      expect(find.textContaining('America/New_York'), findsOneWidget);
      await tester.enterText(
        find.byType(TextFormField).at(0),
        'Tagihan zona asal',
      );
      await tester.enterText(find.byType(TextFormField).at(1), '125000');
      await tester.ensureVisible(find.text('Simpan tagihan'));
      await tester.tap(find.text('Simpan tagihan'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      final saved = (await repository.listBills()).single;
      expect(saved.timezone, 'America/New_York');
      expect(billCalendarDate(saved.dueAt, saved.timezone).hour, 9);
    },
  );

  TransactionRepository createRepository() => TransactionRepository(
    factory: databaseFactoryFfiNoIsolate,
    databasePath: inMemoryDatabasePath,
  );

  testWidgets('shows add transaction action', (tester) async {
    final repository = createRepository();
    addTearDown(repository.close);
    await tester.pumpWidget(
      MaterialApp(home: TransactionsScreen(repository: repository)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Tambah transaksi'), findsOneWidget);
  });

  testWidgets('rejects negative transaction amount', (tester) async {
    final repository = createRepository();
    addTearDown(repository.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TransactionForm(repository: repository)),
      ),
    );

    await tester.enterText(find.byType(TextFormField).first, '-1');
    await tester.ensureVisible(find.text('Simpan transaksi'));
    await tester.tap(find.text('Simpan transaksi'));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();

    expect(find.text('Masukkan nominal valid lebih dari 0.'), findsOneWidget);
  });

  testWidgets('opens bills tab from navigation', (tester) async {
    final repository = createRepository();
    addTearDown(repository.close);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          repository: repository,
          onSettingsChanged: (_) {},
          reminders: _NoopReminderService(),
        ),
      ),
    );
    await tester.tap(find.text('Tagihan'));
    await tester.pumpAndSettle();

    expect(find.text('Tambah tagihan'), findsOneWidget);
  });

  testWidgets('shows currency and local-data controls', (tester) async {
    final repository = createRepository();
    addTearDown(repository.close);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          repository: repository,
          settings: const AppSettings(),
          onChanged: (_) {},
        ),
      ),
    );

    expect(find.text('Mata uang'), findsOneWidget);
    expect(find.text('Awal periode bulanan'), findsOneWidget);
    expect(find.text('Tema gelap'), findsOneWidget);
    expect(find.text('Hapus semua data lokal'), findsOneWidget);
  });

  testWidgets('saves bill and keeps it after screen rebuild', (tester) async {
    final repository = createRepository();
    addTearDown(repository.close);
    await tester.pumpWidget(
      MaterialApp(
        home: BillsScreen(
          repository: repository,
          reminders: _NoopReminderService(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Tambah tagihan'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextFormField).at(0), 'Internet');
    await tester.enterText(find.byType(TextFormField).at(1), '125000');
    await tester.ensureVisible(find.text('Simpan tagihan'));
    await tester.tap(find.text('Simpan tagihan'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('Internet'), findsOneWidget);
    expect((await repository.listBills()).single.name, 'Internet');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(
        home: BillsScreen(
          repository: repository,
          reminders: _NoopReminderService(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Internet'), findsOneWidget);
    expect((await repository.listBills()).single.amount, 125000);
  });

  testWidgets('edits and deletes transaction through actions', (tester) async {
    final repository = createRepository();
    addTearDown(repository.close);
    await repository.save(
      MoneyTransaction(
        id: null,
        type: TransactionType.expense,
        amount: 125000,
        category: 'Makan',
        occurredAt: DateTime.now(),
        note: 'Siang',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: TransactionsScreen(repository: repository)),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byTooltip('Aksi transaksi'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Ubah'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '200000');
    await tester.ensureVisible(find.text('Simpan transaksi'));
    await tester.tap(find.text('Simpan transaksi'));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(
      (await repository.list(
        periodStart: DateTime(DateTime.now().year, DateTime.now().month, 1),
      )).single.amount,
      200000,
    );

    await tester.tap(find.byTooltip('Aksi transaksi'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hapus').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hapus').last);
    await tester.pumpAndSettle();
    expect(
      await repository.list(
        periodStart: DateTime(DateTime.now().year, DateTime.now().month, 1),
      ),
      isEmpty,
    );
  });

  testWidgets('requires bill name before saving', (tester) async {
    final repository = createRepository();
    addTearDown(repository.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BillForm(
            repository: repository,
            reminders: ReminderService(),
            currencyCode: 'IDR',
            notificationsEnabled: true,
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextFormField).last, '250000');
    await tester.ensureVisible(find.text('Simpan tagihan'));
    await tester.tap(find.text('Simpan tagihan'));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();

    expect(find.text('Masukkan nama tagihan.'), findsOneWidget);
  });
  for (final enabled in [true, false]) {
    testWidgets(
      'payment respects notification setting $enabled and anchor date',
      (tester) async {
        final repository = createRepository();
        addTearDown(repository.close);
        await repository.saveBill(
          Bill(
            id: null,
            name: 'Sewa',
            amount: 1000,
            dueAt: DateTime(2030, 2, 28, 9),
            recurrence: BillRecurrence.monthly,
            recurrenceDay: 31,
            reminderMinutes: 60,
            status: BillStatus.active,
          ),
        );
        final reminders = _NoopReminderService();
        await tester.pumpWidget(
          MaterialApp(
            home: BillsScreen(
              repository: repository,
              reminders: reminders,
              settings: AppSettings(notificationsEnabled: enabled),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Aksi tagihan'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tandai lunas'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sudah lunas'));
        await tester.pumpAndSettle();
        expect(
          (await repository.listBills()).single.dueAt,
          DateTime(2030, 3, 31, 9),
        );
        expect(reminders.scheduled, hasLength(enabled ? 1 : 0));
        if (enabled) {
          expect(reminders.scheduled.single.dueAt, DateTime(2030, 3, 31, 9));
        }
      },
    );
  }

  testWidgets('clearing data refreshes both retained tabs', (tester) async {
    final repository = createRepository();
    addTearDown(repository.close);
    await repository.save(
      MoneyTransaction(
        id: null,
        type: TransactionType.expense,
        amount: 500,
        category: 'Makan',
        occurredAt: DateTime.now(),
        note: 'Contoh unik',
      ),
    );
    await repository.saveBill(
      Bill(
        id: null,
        name: 'Tagihan unik',
        amount: 1000,
        dueAt: DateTime(2030, 1, 1),
        recurrence: BillRecurrence.once,
        reminderMinutes: null,
        status: BillStatus.active,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          repository: repository,
          onSettingsChanged: (_) {},
          reminders: _NoopReminderService(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pengaturan').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Hapus semua data lokal'),
      300,
      scrollable: find.descendant(
        of: find.byType(SettingsScreen),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hapus semua data lokal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hapus semua'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Catatan').last);
    await tester.pumpAndSettle();
    expect(find.text('Belum ada transaksi periode ini.'), findsOneWidget);
    await tester.tap(find.text('Tagihan').last);
    await tester.pumpAndSettle();
    expect(find.text('Tagihan unik'), findsNothing);
    expect(await repository.hasEntries(), isFalse);
  });
  testWidgets('startup and resume restore reminder schedules', (tester) async {
    final repository = createRepository();
    addTearDown(repository.close);
    await repository.saveBill(
      Bill(
        id: null,
        name: 'Internet',
        amount: 100,
        dueAt: DateTime(2030),
        recurrence: BillRecurrence.once,
        reminderMinutes: 60,
        status: BillStatus.active,
      ),
    );
    final reminders = _NoopReminderService();
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          repository: repository,
          onSettingsChanged: (_) {},
          reminders: reminders,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(reminders.scheduled, hasLength(1));
    reminders.scheduled.clear();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(reminders.scheduled, hasLength(1));
  });
}
