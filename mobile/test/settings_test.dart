import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:catat_uang/bill.dart';
import 'package:catat_uang/settings.dart';
import 'package:catat_uang/transaction.dart';
import 'package:catat_uang/transaction_repository.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('calculates custom period start across month boundaries', () {
    expect(periodStartFor(DateTime(2026, 5, 14), 15), DateTime(2026, 4, 15));
    expect(periodStartFor(DateTime(2026, 5, 15), 15), DateTime(2026, 5, 15));
  });

  test('adds dark mode setting when upgrading schema version four', () async {
    final databasePath = path.join(
      await databaseFactoryFfi.getDatabasesPath(),
      'settings_upgrade_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    final oldDatabase = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE transactions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              type TEXT NOT NULL,
              amount INTEGER NOT NULL,
              category TEXT NOT NULL,
              occurred_at TEXT NOT NULL,
              note TEXT NOT NULL DEFAULT ''
            )
          ''');
          await db.execute('''
            CREATE TABLE bills (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              amount INTEGER NOT NULL,
              due_at TEXT NOT NULL,
              recurrence TEXT NOT NULL,
              reminder_minutes INTEGER,
              status TEXT NOT NULL,
              paid_at TEXT
            )
          ''');
          await db.execute('''
            CREATE TABLE bill_payments (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              bill_id INTEGER NOT NULL,
              due_at TEXT NOT NULL,
              amount INTEGER NOT NULL,
              paid_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE settings (
              id INTEGER PRIMARY KEY,
              currency_code TEXT NOT NULL,
              month_start_day INTEGER NOT NULL,
              notifications_enabled INTEGER NOT NULL
            )
          ''');
          await db.insert('bills', {
            'name': 'Sewa',
            'amount': 150000,
            'due_at': '2025-01-31T09:00:00.000',
            'recurrence': 'monthly',
            'reminder_minutes': null,
            'status': 'active',
            'paid_at': null,
          });
          await db.insert('settings', {
            'id': 1,
            'currency_code': 'USD',
            'month_start_day': 15,
            'notifications_enabled': 0,
          });
        },
      ),
    );
    await oldDatabase.close();

    final repository = TransactionRepository(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    addTearDown(() async {
      await repository.close();
      await databaseFactoryFfi.deleteDatabase(databasePath);
    });

    final settings = await repository.getSettings();
    expect(settings.currencyCode, 'USD');
    expect(settings.monthStartDay, 15);
    expect(settings.notificationsEnabled, isFalse);
    expect(settings.darkMode, isFalse);
    expect((await repository.listBills()).single.recurrenceDay, 31);
  });

  test('persists settings and resets local data to defaults', () async {
    final repository = TransactionRepository(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    addTearDown(repository.close);

    await repository.saveSettings(
      const AppSettings(
        currencyCode: 'USD',
        monthStartDay: 15,
        notificationsEnabled: false,
        darkMode: true,
      ),
    );
    final saved = await repository.getSettings();
    expect(saved.currencyCode, 'USD');
    expect(saved.monthStartDay, 15);
    expect(saved.notificationsEnabled, isFalse);
    expect(saved.darkMode, isTrue);

    await repository.save(
      MoneyTransaction(
        id: null,
        type: TransactionType.expense,
        amount: 250,
        category: 'Makan',
        occurredAt: DateTime(2026, 1, 1),
      ),
    );
    await repository.saveBill(
      Bill(
        id: null,
        name: 'Sewa',
        amount: 500,
        dueAt: DateTime(2026, 1, 1),
        recurrence: BillRecurrence.once,
        reminderMinutes: null,
        status: BillStatus.active,
      ),
    );
    expect(await repository.hasEntries(), isTrue);

    await repository.clearAllData();

    final reset = await repository.getSettings();
    expect(reset.currencyCode, 'IDR');
    expect(reset.monthStartDay, 1);
    expect(reset.notificationsEnabled, isTrue);
    expect(reset.darkMode, isFalse);
    expect(await repository.hasEntries(), isFalse);
    expect(await repository.list(periodStart: DateTime(2026, 1)), isEmpty);
    expect(await repository.listBills(), isEmpty);
  });
}
