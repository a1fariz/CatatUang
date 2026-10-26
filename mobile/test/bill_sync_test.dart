import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:catat_uang/bill.dart';
import 'package:catat_uang/settings.dart';
import 'package:catat_uang/sync/bill_sync_models.dart';
import 'package:catat_uang/sync/sync_models.dart';
import 'package:catat_uang/transaction_repository.dart';

const owner = '10000000-0000-4000-8000-000000000001';
const epoch = '20000000-0000-4000-8000-000000000001';
Bill bill({int? id, String name = 'Internet'}) => Bill(
  id: id,
  name: name,
  amount: 250000,
  dueAt: DateTime(2026, 10, 26, 9),
  recurrence: BillRecurrence.monthly,
  recurrenceDay: 26,
  reminderMinutes: 60,
  status: BillStatus.active,
);
BillSyncRecord receipt(SyncOperation op, int version) =>
    BillSyncRecord.fromJson({
      ...op.payload!,
      'id': op.remoteId,
      'version': version,
      'deleted': op.deleted,
      'created_at': '2026-10-26T00:00:00Z',
      'updated_at': '2026-10-26T00:00:00Z',
    });

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory folder;
  late TransactionRepository a, b;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('catat-bill-sync-');
    a = TransactionRepository(
      factory: databaseFactoryFfiNoIsolate,
      databasePath: '${folder.path}/a.db',
    );
    b = TransactionRepository(
      factory: databaseFactoryFfiNoIsolate,
      databasePath: '${folder.path}/b.db',
    );
  });
  tearDown(() async {
    await a.close();
    await b.close();
    await folder.delete(recursive: true);
  });
  test(
    'version 1 external backups remain readable without opting into bill sync',
    () async {
      await a.saveBill(bill());
      final snapshot = jsonDecode(jsonEncode(await a.backupSnapshot())) as Map<String,dynamic>;
      snapshot['version'] = 1;
      (snapshot['tables'] as Map).removeWhere(
        (key, value) => (key as String).startsWith('bill_sync_'),
      );
      for (final row in (snapshot['tables'] as Map)['bills'] as List) {
        (row as Map).remove('timezone');
      }
      await b.restoreExternalBackup(snapshot);
      expect(await b.listBills(), hasLength(1));
      expect(await b.billSyncBinding(), isNull);
    },
  );
  Future<SyncBinding> link(TransactionRepository repo) async {
    await repo.linkBillSync(
      server: Uri.parse('http://127.0.0.1:8080/'),
      userId: owner,
      email: 'test@example.com',
      timezone: 'Asia/Jakarta',
    );
    final binding = (await repo.billSyncBinding())!;
    await repo.pinBillDataset(binding.generation, epoch);
    return (await repo.billSyncBinding())!;
  }

  test(
    'bill consent is separate; inflight operation survives edits, reopen and backup',
    () async {
      final id = await a.saveBill(bill());
      expect(await a.billSyncPendingCount(), 0);
      final binding = await link(a);
      final first = (await a.nextBillOperation(binding.generation))!;
      await a.saveBill(bill(id: id, name: 'Internet rumah'));
      expect(await a.billSyncPendingCount(), 2);
      await a.close();
      final retry = (await a.nextBillOperation(
        binding.generation,
        inflightOnly: true,
      ))!;
      expect(jsonEncode(retry.toJson()), jsonEncode(first.toJson()));
      await b.restoreExternalBackup(await a.backupSnapshot());
      final restored = (await b.billSyncBinding())!;
      expect(restored.generation, isNot(binding.generation));
      expect(
        jsonEncode(
          (await b.nextBillOperation(
            restored.generation,
            inflightOnly: true,
          ))!.toJson(),
        ),
        jsonEncode(first.toJson()),
      );
      await a.acknowledgeBill(binding.generation, first, receipt(first, 1));
      final pending = (await a.nextBillOperation(binding.generation))!;
      expect(pending.baseVersion, 1);
      expect(pending.payload!['name'], 'Internet rumah');
    },
  );
  test(
    'payment identities transfer once to second database and stale response cannot mutate cleared data',
    () async {
      await a.saveBill(bill());
      final binding = await link(a);
      await a.payBill(
        (await a.listBills()).single,
        DateTime.utc(2026, 10, 26, 3),
      );
      final op = (await a.nextBillOperation(binding.generation))!;
      final record = receipt(op, 2);
      expect(record.payments.length, 1);
      final other = await link(b);
      await b.applyBillPage(other.generation, 0, [record], 2);
      expect((await b.billRecoverySnapshot())['bill_payments'], hasLength(1));
      await b.applyBillPage(other.generation, 2, [record], 2);
      expect((await b.billRecoverySnapshot())['bill_payments'], hasLength(1));
      await a.clearAllData();
      await a.acknowledgeBill(binding.generation, op, record);
      expect(await a.billSyncBinding(), isNull);
      expect(await a.listBills(), isEmpty);
    },
  );
  test('conflicts preserve local bill until explicit account choice', () async {
    final id = await a.saveBill(bill());
    final binding = await link(a);
    final op = (await a.nextBillOperation(binding.generation))!;
    final record = receipt(op, 1);
    await a.saveBill(bill(id: id, name: 'Versi lokal'));
    await a.applyBillPage(binding.generation, 0, [record], 1);
    expect((await a.listBills()).single.name, 'Versi lokal');
    expect(await a.billSyncIssues(), hasLength(1));
    await a.resolveBill(binding.generation, record.id, useServer: true);
    expect((await a.listBills()).single.name, 'Internet');
    expect(await a.billSyncPendingCount(), 0);
  });
  test(
    'dataset recovery freezes preview, saves backup, preserves local-only and rotates operation IDs',
    () async {
      await a.saveBill(bill());
      final binding = await link(a);
      final old = (await a.nextBillOperation(binding.generation))!;
      await expectLater(
        a.pinBillDataset(binding.generation, syncId()),
        throwsA(isA<SyncFailure>()),
      );
      final before = await a.billRecoverySnapshot();
      await a.saveBill(bill(name: 'Baru'));
      await expectLater(
        a.reconcileBillDataset(
          binding.generation,
          syncId(),
          jsonEncode(before),
          [],
        ),
        throwsA(isA<SyncFailure>()),
      );
      final fresh = await a.billRecoverySnapshot();
      final dataset = syncId();
      await a.reconcileBillDataset(
        binding.generation,
        dataset,
        jsonEncode(fresh),
        [],
      );
      expect(await a.listBills(), hasLength(2));
      final updated = (await a.billSyncBinding())!;
      expect(updated.datasetId, dataset);
      expect(updated.generation, isNot(binding.generation));
      final next = (await a.nextBillOperation(updated.generation))!;
      expect(next.operationId, isNot(old.operationId));
      expect(next.baseVersion, 0);
      final snapshot = await a.backupSnapshot();
      expect(
        (snapshot['tables'] as Map)['bill_sync_recovery_backups'],
        hasLength(1),
      );
    },
  );
  test(
    'bill binding protects currency and account, recurrence preserves originating zone across DST',
    () async {
      await link(a);
      await expectLater(
        a.saveSettings(const AppSettings(currencyCode: 'USD')),
        throwsStateError,
      );
      await expectLater(
        a.linkSync(
          server: Uri.parse('http://127.0.0.1:8080/'),
          userId: syncId(),
          email: 'other@example.com',
        ),
        throwsA(isA<SyncFailure>()),
      );
      final zoned = Bill(
        id: 1,
        name: 'DST',
        amount: 1,
        dueAt: DateTime.utc(2026, 3, 7, 14),
        recurrence: BillRecurrence.weekly,
        reminderMinutes: null,
        status: BillStatus.active,
        timezone: 'America/New_York',
      );
      expect(nextZonedBillDue(zoned).toUtc(), DateTime.utc(2026, 3, 14, 13));
    },
  );
}
