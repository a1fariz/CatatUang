import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:catat_uang/transaction.dart';
import 'package:catat_uang/bill.dart';
import 'package:catat_uang/settings.dart';
import 'package:catat_uang/transaction_repository.dart';

void main() {
  late TransactionRepository repository;

  setUpAll(sqfliteFfiInit);

  setUp(() {
    repository = TransactionRepository(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
  });

  tearDown(() async {
    await repository.close();
  });

  test('saves, filters by month, updates and deletes transactions', () async {
    final id = await repository.save(
      MoneyTransaction(
        id: null,
        type: TransactionType.expense,
        amount: 42000,
        category: 'Makan',
        occurredAt: DateTime(2025, 4, 30),
        note: 'Makan siang',
      ),
    );
    await repository.save(
      MoneyTransaction(
        id: null,
        type: TransactionType.income,
        amount: 80000,
        category: 'Bonus',
        occurredAt: DateTime(2025, 5, 1),
      ),
    );

    final april = await repository.list(periodStart: DateTime(2025, 4));
    expect(april, hasLength(1));
    expect(april.single.amount, 42000);
    expect(april.single.note, 'Makan siang');

    await repository.save(
      MoneyTransaction(
        id: id,
        type: TransactionType.expense,
        amount: 45000,
        category: 'Belanja',
        occurredAt: DateTime(2025, 4, 30),
      ),
    );
    expect(
      (await repository.list(periodStart: DateTime(2025, 4))).single.amount,
      45000,
    );

    await repository.delete(id);
    expect(await repository.list(periodStart: DateTime(2025, 4)), isEmpty);
    expect(await repository.list(periodStart: DateTime(2025, 5)), hasLength(1));
  });

  test('database rejects non-positive amounts', () async {
    expect(
      () => repository.save(
        MoneyTransaction(
          id: null,
          type: TransactionType.expense,
          amount: 0,
          category: 'Makan',
          occurredAt: DateTime(2025, 4, 1),
        ),
      ),
      throwsA(isA<DatabaseException>()),
    );
  });
  test('transaction and paid recurring bill survive database reopen', () async {
    final directory = await Directory.systemTemp.createTemp('catat_uang_');
    final databasePath = path.join(directory.path, 'persistence.db');
    var disk = TransactionRepository(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    addTearDown(() async {
      await disk.close();
      await directory.delete(recursive: true);
    });
    await disk.save(
      MoneyTransaction(
        id: null,
        type: TransactionType.expense,
        amount: 42000,
        category: 'Makan',
        occurredAt: DateTime(2026, 10, 25),
      ),
    );
    await disk.saveBill(
      Bill(
        id: null,
        name: 'Sewa',
        amount: 1000,
        dueAt: DateTime(2026, 1, 31),
        recurrence: BillRecurrence.monthly,
        recurrenceDay: 31,
        reminderMinutes: 60,
        status: BillStatus.active,
      ),
    );
    await disk.payBill((await disk.listBills()).single, DateTime(2026, 1, 31));
    await disk.saveSettings(
      const AppSettings(notificationsEnabled: false, darkMode: true),
    );
    await disk.close();
    disk = TransactionRepository(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    expect(
      (await disk.list(periodStart: DateTime(2026, 10))).single.amount,
      42000,
    );
    expect((await disk.listBills()).single.dueAt, DateTime(2026, 2, 28));
    expect((await disk.listBills()).single.recurrenceDay, 31);
    expect((await disk.getSettings()).notificationsEnabled, isFalse);
    expect((await disk.getSettings()).darkMode, isTrue);
    await disk.payBill((await disk.listBills()).single, DateTime(2026, 2, 28));
    expect((await disk.listBills()).single.dueAt, DateTime(2026, 3, 31));
  });
}
