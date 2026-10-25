import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:catat_uang/bill.dart';
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

  tearDown(() => repository.close());

  test('monthly recurrence clamps to last day of shorter month', () {
    expect(
      nextDueDate(DateTime(2025, 1, 31, 9), BillRecurrence.monthly),
      DateTime(2025, 2, 28, 9),
    );
    expect(
      nextDueDate(DateTime(2024, 1, 31, 9), BillRecurrence.monthly),
      DateTime(2024, 2, 29, 9),
    );
    expect(
      nextDueDate(
        DateTime(2025, 2, 28, 9),
        BillRecurrence.monthly,
        recurrenceDay: 31,
      ),
      DateTime(2025, 3, 31, 9),
    );
  });

  test('yearly recurrence clamps leap day in non-leap year', () {
    expect(
      nextDueDate(DateTime(2024, 2, 29, 9), BillRecurrence.yearly),
      DateTime(2025, 2, 28, 9),
    );
    expect(
      nextDueDate(
        DateTime(2025, 2, 28, 9),
        BillRecurrence.yearly,
        recurrenceDay: 29,
      ),
      DateTime(2026, 2, 28, 9),
    );
    expect(
      nextDueDate(
        DateTime(2027, 2, 28, 9),
        BillRecurrence.yearly,
        recurrenceDay: 29,
      ),
      DateTime(2028, 2, 29, 9),
    );
  });

  test('paying recurring bill records payment and advances due date', () async {
    final id = await repository.saveBill(
      Bill(
        id: null,
        name: 'Sewa',
        amount: 1500000,
        dueAt: DateTime(2025, 1, 31, 9),
        recurrence: BillRecurrence.monthly,
        recurrenceDay: 31,
        reminderMinutes: 60,
        status: BillStatus.active,
      ),
    );
    final bill = (await repository.listBills()).single;

    await repository.payBill(bill, DateTime(2025, 1, 31, 10));
    await expectLater(
      repository.payBill(bill, DateTime(2025, 1, 31, 10)),
      throwsStateError,
    );

    final next = (await repository.listBills()).single;
    expect(next.id, id);
    expect(next.dueAt, DateTime(2025, 2, 28, 9));
    expect(next.recurrenceDay, 31);
    expect(next.reminderMinutes, 60);

    await repository.payBill(next, DateTime(2025, 2, 28, 10));
    expect(
      (await repository.listBills()).single.dueAt,
      DateTime(2025, 3, 31, 9),
    );

    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final payments = await db.query('bill_payments');
    expect(payments, hasLength(2));
    expect(payments.map((payment) => payment['amount']), everyElement(1500000));
    expect(payments.map((payment) => payment['due_at']), [
      '2025-01-31T09:00:00.000',
      '2025-02-28T09:00:00.000',
    ]);
  });

  test('paying one-time bill removes it from active bills', () async {
    await repository.saveBill(
      Bill(
        id: null,
        name: 'Pajak',
        amount: 250000,
        dueAt: DateTime(2025, 1, 31, 9),
        recurrence: BillRecurrence.once,
        reminderMinutes: null,
        status: BillStatus.active,
      ),
    );
    final bill = (await repository.listBills()).single;

    await repository.payBill(bill, DateTime(2025, 1, 31, 10));

    expect(await repository.listBills(), isEmpty);
  });
}
