part of '../transaction_repository.dart';

extension DemoRepository on TransactionRepository {
  Future<bool> seedDemoData(DateTime now) async {
    if (_databasePath == null ||
        path.basename(_databasePath) != 'catat_uang_demo.db') {
      throw StateError('Sample data requires the isolated demo database');
    }
    final db = await _db;
    return db.transaction((txn) async {
      await txn.execute(
        'CREATE TABLE IF NOT EXISTS demo_seed (id INTEGER PRIMARY KEY CHECK(id=1))',
      );
      if ((await txn.query('demo_seed')).isNotEmpty) return false;
      await txn.insert('demo_seed', {'id': 1});
      // Never add samples to an existing ledger, even on an older demo build.
      for (final table in ['transactions', 'bills', 'bill_payments']) {
        if ((await txn.query(table, limit: 1)).isNotEmpty) return false;
      }
      final samples = [
        (TransactionType.income, 6500000, 'Gaji', 1, 'Gaji bulanan • contoh'),
        (
          TransactionType.expense,
          350000,
          'Belanja',
          3,
          'Belanja kebutuhan rumah • contoh',
        ),
        (TransactionType.expense, 45000, 'Makan', 5, 'Makan siang • contoh'),
        (
          TransactionType.expense,
          75000,
          'Transportasi',
          8,
          'Perjalanan harian • contoh',
        ),
        (
          TransactionType.income,
          500000,
          'Lainnya',
          12,
          'Proyek sampingan • contoh',
        ),
        (
          TransactionType.expense,
          180000,
          'Belanja',
          15,
          'Persediaan mingguan • contoh',
        ),
        (TransactionType.expense, 28000, 'Makan', 18, 'Sarapan • contoh'),
        (
          TransactionType.expense,
          120000,
          'Hiburan',
          22,
          'Buku dan hiburan • contoh',
        ),
      ];
      for (final item in samples) {
        await txn.insert(
          'transactions',
          MoneyTransaction(
            id: null,
            type: item.$1,
            amount: item.$2,
            category: item.$3,
            occurredAt: DateTime(now.year, now.month, item.$4),
            note: item.$5,
          ).toMap(),
        );
      }
      await txn.insert(
        'bills',
        Bill(
          id: null,
          name: 'Internet rumah • contoh',
          amount: 350000,
          dueAt: now.add(const Duration(days: 4)),
          recurrence: BillRecurrence.monthly,
          reminderMinutes: null,
          status: BillStatus.active,
        ).toMap(),
      );
      final paid = Bill(
        id: null,
        name: 'Listrik • contoh',
        amount: 220000,
        dueAt: DateTime(now.year, now.month, 1),
        recurrence: BillRecurrence.once,
        reminderMinutes: null,
        status: BillStatus.paid,
        paidAt: now,
      );
      final paidId = await txn.insert('bills', paid.toMap());
      await txn.insert('bill_payments', {
        'bill_id': paidId,
        'due_at': paid.dueAt.toIso8601String(),
        'amount': paid.amount,
        'paid_at': now.toIso8601String(),
      });
      await txn.update('settings', {'notifications_enabled': 0}, where: 'id=1');
      return true;
    });
  }
}
