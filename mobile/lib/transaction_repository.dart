import 'dart:convert';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'bill.dart';
import 'settings.dart';
import 'transaction.dart';
import 'sync/sync_models.dart';
import 'sync/sync_recovery.dart';
import 'backup/backup_codec.dart';
import 'sync/bill_sync_models.dart';

part 'sync/sync_repository.dart';
part 'sync/recovery_repository.dart';
part 'backup/backup_repository.dart';
part 'sync/bill_sync_repository.dart';
part 'demo/demo_repository.dart';

class TransactionRepository {
  TransactionRepository({DatabaseFactory? factory, String? databasePath})
    : _factory = factory ?? databaseFactory,
      _databasePath = databasePath;

  final DatabaseFactory _factory;
  final String? _databasePath;
  Database? _database;
  Future<Database>? _opening;

  Future<void> _createBillsTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS bills (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL CHECK (length(trim(name)) > 0),
        amount INTEGER NOT NULL CHECK (amount > 0),
        due_at TEXT NOT NULL,
        recurrence TEXT NOT NULL CHECK (recurrence IN ('once', 'weekly', 'monthly', 'yearly')),
        recurrence_day INTEGER NOT NULL DEFAULT 1 CHECK (recurrence_day BETWEEN 1 AND 31),
        reminder_minutes INTEGER,
        status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paid', 'cancelled')),
        paid_at TEXT,
        timezone TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS bill_payments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bill_id INTEGER NOT NULL,
        due_at TEXT NOT NULL,
        amount INTEGER NOT NULL CHECK (amount > 0),
        paid_at TEXT NOT NULL
      )
    ''');
  }

  Future<void> _createSettingsTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        currency_code TEXT NOT NULL DEFAULT 'IDR',
        month_start_day INTEGER NOT NULL DEFAULT 1 CHECK (month_start_day BETWEEN 1 AND 28),
        notifications_enabled INTEGER NOT NULL DEFAULT 1 CHECK (notifications_enabled IN (0, 1)),
        dark_mode INTEGER NOT NULL DEFAULT 0 CHECK (dark_mode IN (0, 1))
      )
    ''');
    await db.insert(
      'settings',
      const AppSettings().toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<Database> get _db async {
    if (_database case final database?) return database;
    return _opening ??= _open();
  }

  Future<Database> _open() async {
    try {
      final database = await _factory.openDatabase(
        _databasePath ??
            path.join(await _factory.getDatabasesPath(), 'catat_uang.db'),
        options: OpenDatabaseOptions(
          version: 10,
          onCreate: (db, version) async {
            await db.execute('''
            CREATE TABLE transactions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              type TEXT NOT NULL CHECK (type IN ('income', 'expense')),
              amount INTEGER NOT NULL CHECK (amount > 0),
              category TEXT NOT NULL,
              occurred_at TEXT NOT NULL,
              note TEXT NOT NULL DEFAULT ''
            )
          ''');
            await _createBillsTables(db);
            await _createSettingsTable(db);
            await _createSyncTables(db);
            await _createRecoveryTable(db);
            await _createBillSyncTables(db);
          },
          onUpgrade: (db, oldVersion, newVersion) async {
            if (oldVersion < 10) {
              if (oldVersion >= 3) {
                await db.execute('ALTER TABLE bills ADD COLUMN timezone TEXT');
              }
              await _createBillSyncTables(db);
            }
            if (oldVersion < 9) await _createRecoveryTable(db);
            if (oldVersion < 7) await _createSyncTables(db);
            if (oldVersion == 7) {
              await db.execute(
                'ALTER TABLE sync_binding ADD COLUMN dataset_id TEXT',
              );
            }
            if (oldVersion < 3) await _createBillsTables(db);
            if (oldVersion < 4) await _createSettingsTable(db);
            if (oldVersion >= 4 && oldVersion < 5) {
              await db.execute(
                'ALTER TABLE settings ADD COLUMN dark_mode INTEGER NOT NULL DEFAULT 0 CHECK (dark_mode IN (0, 1))',
              );
            }
            if (oldVersion >= 3 && oldVersion < 6) {
              await db.execute(
                'ALTER TABLE bills ADD COLUMN recurrence_day INTEGER NOT NULL DEFAULT 1 CHECK (recurrence_day BETWEEN 1 AND 31)',
              );
              await db.execute(
                'UPDATE bills SET recurrence_day = CAST(substr(due_at, 9, 2) AS INTEGER)',
              );
            }
          },
        ),
      );
      _database = database;
      return database;
    } finally {
      _opening = null;
    }
  }

  Future<bool> hasEntries() async {
    final db = await _db;
    final transactions = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM transactions'),
    )!;
    final bills = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM bills'),
    )!;
    return transactions > 0 || bills > 0;
  }

  Future<AppSettings> getSettings() async {
    final rows = await (await _db).query('settings', where: 'id = 1');
    if (rows.isNotEmpty) return AppSettings.fromMap(rows.single);
    await saveSettings(const AppSettings());
    return const AppSettings();
  }

  Future<void> saveSettings(AppSettings settings) async {
    await (await _db).transaction((txn) async {
      final binding = await _binding(txn);
      final billBinding = await _billBinding(txn);
      if (binding != null && binding.currency != settings.currencyCode ||
          billBinding != null &&
              billBinding.currency != settings.currencyCode) {
        throw StateError('Currency is bound to a sync ledger');
      }
      await txn.insert(
        'settings',
        settings.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<void> clearAllData() async {
    final db = await _db;
    await db.transaction((txn) async {
      for (final table in [
        'bill_sync_outbox',
        'bill_sync_maps',
        'bill_sync_payment_ids',
        'bill_sync_binding',
        'bill_sync_recovery_backups',
      ]) {
        await txn.delete(table);
      }
      await txn.delete('sync_outbox');
      await txn.delete('sync_recovery_backups');
      await txn.delete('sync_transactions');
      await txn.delete('sync_binding');
      await txn.delete('transactions');
      await txn.delete('bill_payments');
      await txn.delete('bills');
      await txn.delete('settings');
      await _createSettingsTable(txn);
    });
  }

  Future<List<Bill>> listBills() async {
    final rows = await (await _db).query(
      'bills',
      where: "status = 'active'",
      orderBy: 'due_at ASC, id ASC',
    );
    return rows.map(Bill.fromMap).toList();
  }

  Future<int> saveBill(Bill bill) async {
    final db = await _db;
    return db.transaction((txn) async {
      if (bill.id == null) {
        final id = await txn.insert('bills', bill.toMap());
        await _queueBill(txn, id);
        return id;
      }
      final count = await txn.update(
        'bills',
        bill.toMap()..remove('id'),
        where: 'id = ?',
        whereArgs: [bill.id],
      );
      if (count > 0) await _queueBill(txn, bill.id!);
      return count;
    });
  }

  Future<void> payBill(Bill bill, DateTime paidAt) async {
    if (bill.id == null || bill.status != BillStatus.active) {
      throw ArgumentError('Only persisted active bills can be paid.');
    }
    final db = await _db;
    await db.transaction((txn) async {
      final result = await txn.update(
        'bills',
        bill.recurrence == BillRecurrence.once
            ? {
                'status': BillStatus.paid.name,
                'paid_at': paidAt.toIso8601String(),
              }
            : {
                'due_at':
                    (bill.timezone != null
                            ? nextZonedBillDue(bill)
                            : nextDueDate(
                                bill.dueAt,
                                bill.recurrence,
                                recurrenceDay: bill.recurrenceDay,
                              ))
                        .toIso8601String(),
                'paid_at': null,
              },
        where: "id = ? AND status = 'active' AND due_at = ?",
        whereArgs: [bill.id, bill.dueAt.toIso8601String()],
      );
      if (result != 1) throw StateError('Bill is no longer active.');
      await txn.insert('bill_payments', {
        'bill_id': bill.id,
        'due_at': bill.dueAt.toIso8601String(),
        'amount': bill.amount,
        'paid_at': paidAt.toIso8601String(),
      });
      await _queueBill(txn, bill.id!);
    });
  }

  Future<int> deleteBill(int id) async {
    final db = await _db;
    return db.transaction((txn) async {
      await txn.delete('bill_payments', where: 'bill_id = ?', whereArgs: [id]);
      final count = await txn.delete('bills', where: 'id = ?', whereArgs: [id]);
      if (count > 0) await _queueBill(txn, id, deleted: true);
      return count;
    });
  }

  Future<List<MoneyTransaction>> list({required DateTime periodStart}) async {
    final start = DateTime(
      periodStart.year,
      periodStart.month,
      periodStart.day,
    );
    final end = DateTime(start.year, start.month + 1, start.day);
    final rows = await (await _db).query(
      'transactions',
      where: 'occurred_at >= ? AND occurred_at < ?',
      whereArgs: [start.toIso8601String(), end.toIso8601String()],
      orderBy: 'occurred_at DESC, id DESC',
    );
    return rows.map(MoneyTransaction.fromMap).toList();
  }

  Future<int> save(MoneyTransaction transaction) async {
    final db = await _db;
    return db.transaction((txn) async {
      if (transaction.id == null) {
        final id = await txn.insert('transactions', transaction.toMap());
        await _queueLocal(txn, id);
        return id;
      }
      final count = await txn.update(
        'transactions',
        transaction.toMap()..remove('id'),
        where: 'id = ?',
        whereArgs: [transaction.id],
      );
      if (count > 0) await _queueLocal(txn, transaction.id!);
      return count;
    });
  }

  Future<int> delete(int id) async => (await _db).transaction((txn) async {
    final count = await txn.delete(
      'transactions',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (count > 0) await _queueLocal(txn, id, deleted: true);
    return count;
  });

  Future<void> close() async {
    await _opening;
    final database = _database;
    _database = null;
    await database?.close();
  }
}
