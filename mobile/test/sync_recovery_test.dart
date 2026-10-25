import 'dart:io';

import 'package:catat_uang/auth/account_controller.dart';
import 'package:catat_uang/bill.dart';
import 'package:catat_uang/sync/sync_controller.dart';
import 'package:catat_uang/sync/sync_models.dart';
import 'package:catat_uang/sync/sync_recovery.dart';
import 'package:catat_uang/transaction_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'auth_fakes.dart';
import 'sync_fakes.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late TransactionRepository repo;
  late AccountController account;
  late FakeSyncGateway gateway;
  late TransactionSyncController sync;
  setUp(() async {
    repo = TransactionRepository(
      factory: databaseFactoryFfiNoIsolate,
      databasePath: inMemoryDatabasePath,
    );
    account = AccountController(
      gateway: FakeAuthGateway(),
      store: MemorySessionStore()..value = testSession(),
    );
    await account.initialize();
    gateway = FakeSyncGateway();
    sync = TransactionSyncController(
      repository: repo,
      account: account,
      gateway: gateway,
    );
  });
  tearDown(() async {
    sync.dispose();
    account.dispose();
    await repo.close();
  });
  test(
    'legacy uncertain upload is reconciled by stable record ID without duplicate create',
    () async {
      await repo.save(localTransaction(note: 'Lokal'));
      await repo.linkSync(
        server: gateway.baseUri,
        userId: testUser.id,
        email: testUser.email,
      );
      final ledger = (await repo.syncBinding())!;
      final uncertain = (await repo.nextSyncOperation(ledger.generation))!;
      gateway.change(remoteRecord(id: uncertain.remoteId, note: 'Lokal'));
      await sync.synchronize();
      expect(sync.resetRequired, isTrue);
      final plan = (await sync.prepareRecovery())!;
      expect(plan.unresolved, 0);
      expect(await sync.applyRecovery(plan), isTrue);
      await sync.synchronize();
      expect(gateway.pushes, 0);
      expect(gateway.records, hasLength(1));
      expect(sync.pending, 0);
      expect(sync.backups, hasLength(1));
    },
  );
  test(
    'write failure rolls back backup, replacement rows and sync metadata together',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'catatuang-recovery-rollback-',
      );
      final file = '${folder.path}/ledger.db';
      final disk = TransactionRepository(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: file,
      );
      try {
        await disk.save(localTransaction(note: 'Harus tetap ada'));
        await disk.linkSync(
          server: gateway.baseUri,
          userId: testUser.id,
          email: testUser.email,
        );
        final snapshot = await disk.recoverySnapshot();
        final plan = RecoveryPlan(
          dataset: syncId(),
          cursor: 0,
          snapshot: snapshot,
          records: {},
        );
        plan.items.single.keepLocal = true;
        final raw = await databaseFactoryFfiNoIsolate.openDatabase(file);
        await raw.execute(
          "CREATE TRIGGER fail_recovery BEFORE INSERT ON transactions BEGIN SELECT RAISE(ABORT,'simulated disk write failure'); END",
        );
        await expectLater(
          disk.applyRecovery(plan),
          throwsA(isA<DatabaseException>()),
        );
        expect(await disk.recoverySnapshot(), snapshot);
        expect(await disk.recoveryBackups(), isEmpty);
      } finally {
        await disk.close();
        await folder.delete(recursive: true);
      }
    },
  );
  Future<(int, String)> seed() async {
    final id = await repo.save(localTransaction(note: 'Sebelum restore'));
    await sync.link();
    await sync.synchronize();
    return (id, gateway.records.keys.single);
  }

  void replaceServer(List<SyncRecord> records) {
    gateway.currentDataset = syncId();
    gateway.records.clear();
    gateway.changes.clear();
    gateway.receipts.clear();
    for (final record in records) {
      gateway.change(record);
    }
  }

  Future<RecoveryPlan> prepare() async {
    await sync.synchronize();
    expect(sync.resetRequired, isTrue);
    final plan = await sync.prepareRecovery();
    expect(plan, isNotNull, reason: sync.message);
    return plan!;
  }

  test(
    'review preserves local rows and requires every known difference to be chosen',
    () async {
      final (id, remote) = await seed();
      await repo.save(localTransaction(id: id, note: 'Perangkat'));
      replaceServer([remoteRecord(id: remote, amount: 50000)]);
      final before = await repo.recoverySnapshot();
      final plan = await prepare();
      expect(plan.unresolved, 1);
      expect(await repo.recoverySnapshot(), before);
      expect(await sync.applyRecovery(plan), isFalse);
      expect(await repo.recoveryBackups(), isEmpty);
      plan.items.single.keepLocal = true;
      expect(await sync.applyRecovery(plan), isTrue);
      expect(
        (await repo.list(periodStart: DateTime(2026, 10))).single.note,
        'Perangkat',
      );
      expect(sync.pending, 1);
      expect(await repo.recoveryBackups(), hasLength(1));
      await sync.synchronize();
      expect(gateway.records[remote]!.json['note'], 'Perangkat');
      expect(gateway.records.length, 1);
    },
  );

  test(
    'account choice imports server-only records without duplicate upload and keeps bills',
    () async {
      final (_, remote) = await seed();
      await repo.saveBill(
        Bill(
          id: null,
          name: 'Listrik',
          amount: 250000,
          dueAt: DateTime(2026, 11, 1),
          recurrence: BillRecurrence.monthly,
          reminderMinutes: null,
          status: BillStatus.active,
        ),
      );
      final extra = syncId();
      replaceServer([
        remoteRecord(id: remote, note: 'Akun setelah restore'),
        remoteRecord(id: extra, note: 'Hanya akun'),
      ]);
      final plan = await prepare();
      for (final item in plan.items) {
        item.keepLocal = false;
      }
      expect(await sync.applyRecovery(plan), isTrue);
      expect(await repo.list(periodStart: DateTime(2026, 10)), hasLength(2));
      expect((await repo.listBills()).single.name, 'Listrik');
      expect(sync.pending, 0);
      final calls = gateway.pushes;
      await sync.synchronize();
      expect(gateway.pushes, calls);
    },
  );

  test(
    'local edit during review prevents atomic apply and leaves no backup or partial state',
    () async {
      final (id, remote) = await seed();
      replaceServer([remoteRecord(id: remote)]);
      final plan = await prepare();
      plan.items.single.keepLocal = false;
      await repo.save(localTransaction(id: id, note: 'Edit selama tinjauan'));
      final afterEdit = await repo.recoverySnapshot();
      expect(await sync.applyRecovery(plan), isFalse);
      expect(sync.message, contains('berubah sejak peninjauan'));
      expect(await repo.recoverySnapshot(), afterEdit);
      expect(await repo.recoveryBackups(), isEmpty);
    },
  );

  test(
    'second server rotation or local clear invalidates an open review',
    () async {
      final (_, remote) = await seed();
      replaceServer([remoteRecord(id: remote)]);
      final plan = await prepare();
      plan.items.single.keepLocal = false;
      gateway.currentDataset = syncId();
      expect(await sync.applyRecovery(plan), isFalse);
      expect(await repo.recoveryBackups(), isEmpty);
      await repo.clearAllData();
      expect(await sync.applyRecovery(plan), isFalse);
      expect(await repo.list(periodStart: DateTime(2026, 10)), isEmpty);
    },
  );

  test(
    'local deletion remains a versioned delete and missing server record uses stable UUID',
    () async {
      final (id, remote) = await seed();
      await repo.delete(id);
      replaceServer([remoteRecord(id: remote)]);
      var plan = await prepare();
      plan.items.single.keepLocal = true;
      expect(await sync.applyRecovery(plan), isTrue);
      await sync.synchronize();
      expect(gateway.records[remote]!.deleted, isTrue);
      final newId = await repo.save(localTransaction(note: 'Offline'));
      final ledger = (await repo.syncBinding())!;
      final queued = (await repo.nextSyncOperation(ledger.generation))!;
      replaceServer([]);
      plan = await prepare();
      for (final item in plan.items) {
        item.keepLocal = item.local != null;
      }
      expect(await sync.applyRecovery(plan), isTrue);
      await sync.synchronize();
      expect(gateway.records[queued.remoteId]!.json['note'], 'Offline');
      expect(
        (await repo.list(periodStart: DateTime(2026, 10))).single.id,
        newId,
      );
    },
  );

  test(
    'backup undo restores exact uncertain operation and clear removes backups',
    () async {
      final (id, remote) = await seed();
      await repo.save(localTransaction(id: id, note: 'Daftar lama'));
      final old = (await repo.syncBinding())!;
      final operation = (await repo.nextSyncOperation(old.generation))!;
      replaceServer([remoteRecord(id: remote, note: 'Daftar akun')]);
      final plan = await prepare();
      plan.items.single.keepLocal = false;
      expect(await sync.applyRecovery(plan), isTrue);
      final backup = sync.backups.single;
      await sync.restoreBackup(backup.id);
      expect(
        (await repo.list(periodStart: DateTime(2026, 10))).single.note,
        'Daftar lama',
      );
      final restored = (await repo.syncBinding())!;
      expect(restored.datasetId, old.datasetId);
      expect(restored.generation, isNot(old.generation));
      expect(
        (await repo.nextSyncOperation(restored.generation))!.toJson(),
        operation.toJson(),
      );
      expect(sync.backups, hasLength(2));
      await repo.clearAllData();
      expect(await repo.recoveryBackups(), isEmpty);
    },
  );

  test('version 8 upgrade preserves pinned ledger and outbox', () async {
    final folder = await Directory.systemTemp.createTemp('catatuang-v8-');
    final file = '${folder.path}/ledger.db';
    final before = TransactionRepository(
      factory: databaseFactoryFfiNoIsolate,
      databasePath: file,
    );
    try {
      await before.linkSync(
        server: gateway.baseUri,
        userId: testUser.id,
        email: testUser.email,
      );
      final ledger = (await before.syncBinding())!;
      await before.pinSyncDataset(ledger.generation, gateway.currentDataset);
      await before.save(localTransaction());
      final operation = (await before.nextSyncOperation(ledger.generation))!;
      await before.close();
      final raw = await databaseFactoryFfiNoIsolate.openDatabase(file);
      await raw.execute('DROP TABLE sync_recovery_backups');
      await raw.setVersion(8);
      await raw.close();
      final upgraded = TransactionRepository(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: file,
      );
      try {
        expect(
          (await upgraded.syncBinding())!.datasetId,
          gateway.currentDataset,
        );
        expect(
          (await upgraded.nextSyncOperation(ledger.generation))!.toJson(),
          operation.toJson(),
        );
        expect(await upgraded.recoveryBackups(), isEmpty);
      } finally {
        await upgraded.close();
      }
    } finally {
      await before.close();
      await folder.delete(recursive: true);
    }
  });
}
