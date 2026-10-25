import 'dart:io';

import 'package:catat_uang/bill.dart';
import 'package:catat_uang/settings.dart';
import 'package:catat_uang/sync/sync_models.dart';
import 'package:catat_uang/transaction_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'auth_fakes.dart';
import 'sync_fakes.dart';

void main() {
  late TransactionRepository repo;
  final server = Uri.parse('https://api.example.com/');
  setUpAll(sqfliteFfiInit);
  setUp(() {
    repo = TransactionRepository(
      factory: databaseFactoryFfiNoIsolate,
      databasePath: inMemoryDatabasePath,
    );
  });
  tearDown(() async {
    await repo.close();
  });
  test(
    'version 7 migration preserves linked data and queue without guessing dataset',
    () async {
      final folder = await Directory.systemTemp.createTemp('catatuang-v7-');
      final file = '${folder.path}/ledger.db';
      final before = TransactionRepository(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: file,
      );
      try {
        await before.save(localTransaction());
        await before.linkSync(
          server: server,
          userId: testUser.id,
          email: testUser.email,
        );
        final binding = (await before.syncBinding())!;
        final operation = (await before.nextSyncOperation(binding.generation))!;
        await before.close();
        final raw = await databaseFactoryFfiNoIsolate.openDatabase(file);
        await raw.execute('ALTER TABLE sync_binding DROP COLUMN dataset_id');
        await raw.setVersion(7);
        await raw.close();
        final upgraded = TransactionRepository(
          factory: databaseFactoryFfiNoIsolate,
          databasePath: file,
        );
        try {
          expect(
            (await upgraded.syncBinding())!.generation,
            binding.generation,
          );
          expect((await upgraded.syncBinding())!.datasetId, isNull);
          expect(
            (await upgraded.nextSyncOperation(binding.generation))!.toJson(),
            operation.toJson(),
          );
          expect(
            (await upgraded.list(
              periodStart: DateTime(2026, 10),
            )).single.amount,
            42000,
          );
          await expectLater(
            upgraded.pinSyncDataset(binding.generation, syncId()),
            throwsA(isA<SyncFailure>()),
          );
        } finally {
          await upgraded.close();
        }
      } finally {
        await before.close();
        await folder.delete(recursive: true);
      }
    },
  );
  test(
    'legacy uncertain ledger cannot silently adopt a server identity',
    () async {
      await repo.linkSync(
        server: server,
        userId: testUser.id,
        email: testUser.email,
      );
      final ledger = (await repo.syncBinding())!;
      await repo.save(localTransaction());
      final operation = (await repo.nextSyncOperation(ledger.generation))!;
      await expectLater(
        repo.pinSyncDataset(ledger.generation, syncId()),
        throwsA(isA<SyncFailure>()),
      );
      expect((await repo.syncBinding())!.datasetId, isNull);
      expect(
        (await repo.nextSyncOperation(ledger.generation))!.toJson(),
        operation.toJson(),
      );
      expect(await repo.syncPendingCount(), 1);
    },
  );
  Future<SyncBinding> link() async {
    await repo.linkSync(
      server: server,
      userId: testUser.id,
      email: testUser.email,
    );
    return (await repo.syncBinding())!;
  }

  test(
    'local bookkeeping never queues without explicit ledger linking',
    () async {
      await Future.wait([
        repo.getSettings(),
        repo.syncBinding(),
        repo.syncPendingCount(),
      ]);
      final id = await repo.save(localTransaction());
      expect(await repo.syncPendingCount(), 0);
      final ledger = await link();
      expect(await repo.syncPendingCount(), 1);
      await repo.save(localTransaction(id: id, amount: 50000));
      final op = (await repo.nextSyncOperation(ledger.generation))!;
      expect(op.payload!['amount_minor'], 50000);
      expect(op.baseVersion, 0);
      expect(validSyncId(op.operationId), isTrue);
      expect(validSyncId(op.remoteId), isTrue);
    },
  );

  test(
    'inflight body stays immutable and acknowledgement preserves later local edit',
    () async {
      final ledger = await link();
      final id = await repo.save(localTransaction());
      final first = (await repo.nextSyncOperation(ledger.generation))!;
      await repo.save(localTransaction(id: id, amount: 70000, note: 'Baru'));
      final retry = (await repo.nextSyncOperation(ledger.generation))!;
      expect(retry.toJson(), first.toJson());
      expect(await repo.syncPendingCount(), 2);
      await repo.acknowledgeSync(
        ledger.generation,
        first,
        operationReceipt(first),
      );
      expect(
        (await repo.list(periodStart: DateTime(2026, 10))).single.amount,
        70000,
      );
      final next = (await repo.nextSyncOperation(ledger.generation))!;
      expect(next.operationId, isNot(first.operationId));
      expect(next.baseVersion, 1);
      expect(next.payload!['note'], 'Baru');
    },
  );

  test(
    'create then delete cancels unattempted upload but not uncertain upload',
    () async {
      final ledger = await link();
      var id = await repo.save(localTransaction());
      await repo.delete(id);
      expect(await repo.syncPendingCount(), 0);
      id = await repo.save(localTransaction());
      final first = (await repo.nextSyncOperation(ledger.generation))!;
      await repo.delete(id);
      expect(await repo.syncPendingCount(), 2);
      await repo.acknowledgeSync(
        ledger.generation,
        first,
        operationReceipt(first),
      );
      final deletion = (await repo.nextSyncOperation(ledger.generation))!;
      expect(deletion.deleted, isTrue);
      expect(deletion.baseVersion, 1);
    },
  );

  test(
    'pull applies atomically, skips old echoes, and never creates outgoing work',
    () async {
      final ledger = await link();
      final record = remoteRecord();
      await repo.applySyncPage(
        ledger.generation,
        0,
        SyncPage(items: [record], cursor: 1, hasMore: false),
      );
      expect(await repo.syncPendingCount(), 0);
      expect(
        (await repo.list(periodStart: DateTime(2026, 10))).single.note,
        'Akun',
      );
      await repo.applySyncPage(
        ledger.generation,
        1,
        SyncPage(
          items: [remoteRecord(version: 2, deleted: true)],
          cursor: 2,
          hasMore: false,
        ),
      );
      expect(await repo.list(periodStart: DateTime(2026, 10)), isEmpty);
      await repo.applySyncPage(
        ledger.generation,
        2,
        SyncPage(items: [record], cursor: 3, hasMore: false),
      );
      expect(await repo.list(periodStart: DateTime(2026, 10)), isEmpty);
      await repo.applySyncPage(
        ledger.generation,
        3,
        SyncPage(items: [remoteRecord(version: 3)], cursor: 4, hasMore: false),
      );
      expect(await repo.list(periodStart: DateTime(2026, 10)), hasLength(1));
    },
  );

  test(
    'remote conflicts keep local data until an explicit account choice',
    () async {
      final ledger = await link();
      final id = await repo.save(localTransaction(note: 'Perangkat'));
      final op = (await repo.nextSyncOperation(ledger.generation))!;
      final record = remoteRecord(id: op.remoteId, version: 2, note: 'Server');
      await repo.applySyncPage(
        ledger.generation,
        0,
        SyncPage(items: [record], cursor: 2, hasMore: false),
      );
      expect(
        (await repo.list(periodStart: DateTime(2026, 10))).single.note,
        'Perangkat',
      );
      expect(await repo.nextSyncOperation(ledger.generation), isNull);
      expect(await repo.syncIssues(), hasLength(1));
      await repo.resolveSync(ledger.generation, op.remoteId, keepLocal: false);
      expect((await repo.list(periodStart: DateTime(2026, 10))).single.id, id);
      expect(
        (await repo.list(periodStart: DateTime(2026, 10))).single.note,
        'Server',
      );
      expect(await repo.syncPendingCount(), 0);
    },
  );

  test(
    'keeping local deletion rebases on explicit server version with new operation',
    () async {
      final ledger = await link();
      final id = await repo.save(localTransaction());
      final op = (await repo.nextSyncOperation(ledger.generation))!;
      await repo.delete(id);
      await repo.rejectSync(
        ledger.generation,
        op,
        server: remoteRecord(id: op.remoteId, version: 4),
      );
      await repo.resolveSync(ledger.generation, op.remoteId, keepLocal: true);
      final resolved = (await repo.nextSyncOperation(ledger.generation))!;
      expect(resolved.baseVersion, 4);
      expect(resolved.deleted, isTrue);
      expect(resolved.operationId, isNot(op.operationId));
    },
  );

  test(
    'clearing local data invalidates late pages and acknowledgements',
    () async {
      final ledger = await link();
      await repo.save(localTransaction());
      final op = (await repo.nextSyncOperation(ledger.generation))!;
      await repo.clearAllData();
      final newer = await link();
      expect(newer.generation, isNot(ledger.generation));
      expect(
        await repo.applySyncPage(
          ledger.generation,
          0,
          SyncPage(items: [remoteRecord()], cursor: 1, hasMore: false),
        ),
        isFalse,
      );
      await repo.acknowledgeSync(ledger.generation, op, operationReceipt(op));
      expect(await repo.list(periodStart: DateTime(2026, 10)), isEmpty);
      expect(await repo.syncPendingCount(), 0);
      expect((await repo.syncBinding())!.cursor, 0);
    },
  );

  test(
    'foreign currency rolls back entire page and binding prevents currency changes',
    () async {
      final ledger = await link();
      await expectLater(
        repo.applySyncPage(
          ledger.generation,
          0,
          SyncPage(
            items: [
              remoteRecord(),
              remoteRecord(id: syncId(), currency: 'USD'),
            ],
            cursor: 2,
            hasMore: false,
          ),
        ),
        throwsA(isA<SyncFailure>()),
      );
      expect(await repo.list(periodStart: DateTime(2026, 10)), isEmpty);
      expect((await repo.syncBinding())!.cursor, 0);
      await expectLater(
        repo.saveSettings(const AppSettings(currencyCode: 'USD')),
        throwsStateError,
      );
      expect((await repo.getSettings()).currencyCode, 'IDR');
      await expectLater(
        repo.linkSync(
          server: server,
          userId: syncId(),
          email: 'other@example.com',
        ),
        throwsA(isA<SyncFailure>()),
      );
    },
  );

  test(
    'uncertain operation and binding survive SQLite close and reopen',
    () async {
      final folder = await Directory.systemTemp.createTemp('catatuang-sync-');
      final file = '${folder.path}/ledger.db';
      final disk = TransactionRepository(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: file,
      );
      try {
        await disk.save(localTransaction());
        await disk.linkSync(
          server: server,
          userId: testUser.id,
          email: testUser.email,
        );
        final binding = (await disk.syncBinding())!;
        final first = (await disk.nextSyncOperation(binding.generation))!;
        await disk.close();
        final reopened = TransactionRepository(
          factory: databaseFactoryFfiNoIsolate,
          databasePath: file,
        );
        try {
          final retry = (await reopened.nextSyncOperation(
            binding.generation,
            inflightOnly: true,
          ))!;
          expect(retry.toJson(), first.toJson());
          expect(
            (await reopened.list(
              periodStart: DateTime(2026, 10),
            )).single.amount,
            42000,
          );
        } finally {
          await reopened.close();
        }
      } finally {
        await disk.close();
        await folder.delete(recursive: true);
      }
    },
  );

  test(
    'migration from version 6 preserves finances and does not opt into sync',
    () async {
      final folder = await Directory.systemTemp.createTemp('catatuang-v6-');
      final file = '${folder.path}/ledger.db';
      final before = TransactionRepository(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: file,
      );
      try {
        await before.save(localTransaction());
        await before.saveBill(
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
        await before.saveSettings(const AppSettings(darkMode: true));
        await before.close();
        final raw = await databaseFactoryFfiNoIsolate.openDatabase(file);
        for (final table in [
          'sync_outbox',
          'sync_transactions',
          'sync_binding',
        ]) {
          await raw.execute('DROP TABLE $table');
        }
        await raw.setVersion(6);
        await raw.close();
        final migrated = TransactionRepository(
          factory: databaseFactoryFfiNoIsolate,
          databasePath: file,
        );
        try {
          expect(
            (await migrated.list(
              periodStart: DateTime(2026, 10),
            )).single.amount,
            42000,
          );
          expect((await migrated.listBills()).single.name, 'Listrik');
          expect((await migrated.getSettings()).darkMode, isTrue);
          expect(await migrated.syncBinding(), isNull);
          expect(await migrated.syncPendingCount(), 0);
        } finally {
          await migrated.close();
        }
      } finally {
        await before.close();
        await folder.delete(recursive: true);
      }
    },
  );
}
