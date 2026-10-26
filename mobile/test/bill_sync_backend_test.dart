import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:catat_uang/auth/auth_api.dart';
import 'package:catat_uang/bill.dart';
import 'package:catat_uang/transaction_repository.dart';
import 'package:catat_uang/sync/sync_api.dart';
import 'package:catat_uang/sync/bill_sync_models.dart';
import 'package:catat_uang/sync/sync_models.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  const url = String.fromEnvironment('SYNC_TEST_API_URL');
  setUpAll(sqfliteFfiInit);
  test(
    'two SQLite bill ledgers preserve real Go payment receipt, conflict and reopen',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final folder = await Directory.systemTemp.createTemp(
          'catat-real-bills-',
        );
        final a = TransactionRepository(
          factory: databaseFactoryFfiNoIsolate,
          databasePath: '${folder.path}/a.db',
        );
        final b = TransactionRepository(
          factory: databaseFactoryFfiNoIsolate,
          databasePath: '${folder.path}/b.db',
        );
        final server = configuredApiUri(url, allowLocalHttp: true)!;
        final auth = HttpAuthGateway(baseUri: server),
            gateway = HttpTransactionSyncGateway(baseUri: server);
        try {
          final email =
              'bill-${DateTime.now().microsecondsSinceEpoch}@example.com';
          final first = await auth.authenticate(
            email,
            'password-test-tagihan-2026',
            register: true,
          );
          final second = await auth.authenticate(
            email,
            'password-test-tagihan-2026',
            register: false,
          );
          final dataset = await gateway.datasetId(first.token);
          for (final repo in [a, b]) {
            await repo.linkBillSync(
              server: server,
              userId: first.user.id,
              email: email,
              timezone: 'Etc/UTC',
            );
            final binding = (await repo.billSyncBinding())!;
            await repo.pinBillDataset(binding.generation, dataset);
          }
          final ba = (await a.billSyncBinding())!,
              bb = (await b.billSyncBinding())!;
          final id = await a.saveBill(
            Bill(
              id: null,
              name: 'Internet',
              amount: 250000,
              dueAt: DateTime(2026, 10, 26, 9),
              recurrence: BillRecurrence.monthly,
              recurrenceDay: 26,
              reminderMinutes: 60,
              status: BillStatus.active,
            ),
          );
          final create = (await a.nextBillOperation(ba.generation))!;
          final created = BillSyncRecord.fromJson(
            await gateway.requestJson(
              'POST',
              'v1/sync/bills',
              first.token,
              body: create.toJson(),
              dataset: dataset,
            ),
          );
          await a.acknowledgeBill(ba.generation, create, created);
          await b.applyBillPage(bb.generation, 0, [created], 1);
          final billA = (await a.listBills()).single,
              billB = (await b.listBills()).single;
          await a.payBill(billA, DateTime.utc(2026, 10, 26, 3));
          await b.payBill(billB, DateTime.utc(2026, 10, 26, 4));
          final payment = (await a.nextBillOperation(ba.generation))!;
          final payload = jsonEncode(payment.toJson());
          await a.close();
          final retry = (await a.nextBillOperation(
            ba.generation,
            inflightOnly: true,
          ))!;
          expect(jsonEncode(retry.toJson()), payload);
          final paid = BillSyncRecord.fromJson(
            await gateway.requestJson(
              'POST',
              'v1/sync/bills',
              first.token,
              body: retry.toJson(),
              dataset: dataset,
            ),
          );
          final replay = BillSyncRecord.fromJson(
            await gateway.requestJson(
              'POST',
              'v1/sync/bills',
              first.token,
              body: retry.toJson(),
              dataset: dataset,
            ),
          );
          expect(replay.version, paid.version);
          expect(paid.payments, hasLength(1));
          await a.acknowledgeBill(ba.generation, retry, paid);
          final stale = (await b.nextBillOperation(bb.generation))!;
          await expectLater(
            gateway.requestJson(
              'POST',
              'v1/sync/bills',
              second.token,
              body: stale.toJson(),
              dataset: dataset,
            ),
            throwsA(isA<SyncFailure>().having((e) => e.status, 'status', 409)),
          );
          await b.rejectBill(bb.generation, stale, server: paid);
          await b.resolveBill(bb.generation, paid.id, useServer: true);
          expect(
            (await b.billRecoverySnapshot())['bill_payments'],
            hasLength(1),
          );
          expect(
            (await b.listBills()).single.dueAt.toUtc(),
            (await a.listBills()).single.dueAt.toUtc(),
          );
          expect((await a.listBills()).single.id, id);
        } finally {
          auth.close();
          gateway.close();
          await a.close();
          await b.close();
          await folder.delete(recursive: true);
        }
      }, _RealHttp());
    },
    skip: url.isEmpty
        ? 'Set SYNC_TEST_API_URL for real bill backend integration'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
