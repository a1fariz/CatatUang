import 'dart:io';

import 'package:catat_uang/auth/account_controller.dart';
import 'package:catat_uang/auth/auth_api.dart';
import 'package:catat_uang/sync/sync_api.dart';
import 'package:catat_uang/sync/sync_controller.dart';
import 'package:catat_uang/transaction_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'auth_fakes.dart';
import 'sync_fakes.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  const url = String.fromEnvironment('SYNC_TEST_API_URL');
  setUpAll(sqfliteFfiInit);
  test(
    'two persisted SQLite devices synchronize with a real authenticated Go backend',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = configuredApiUri(url, allowLocalHttp: true)!;
        final folder = await Directory.systemTemp.createTemp(
          'catatuang-two-devices-',
        );
        final a = TransactionRepository(
          factory: databaseFactoryFfiNoIsolate,
          databasePath: '${folder.path}/a.db',
        );
        var b = TransactionRepository(
          factory: databaseFactoryFfiNoIsolate,
          databasePath: '${folder.path}/b.db',
        );
        final accountA = AccountController(
          gateway: HttpAuthGateway(baseUri: server),
          store: MemorySessionStore(),
        );
        final accountB = AccountController(
          gateway: HttpAuthGateway(baseUri: server),
          store: MemorySessionStore(),
        );
        final syncA = TransactionSyncController(
          repository: a,
          account: accountA,
          gateway: HttpTransactionSyncGateway(baseUri: server),
        );
        var syncB = TransactionSyncController(
          repository: b,
          account: accountB,
          gateway: HttpTransactionSyncGateway(baseUri: server),
        );
        try {
          final email =
              'sync-${DateTime.now().microsecondsSinceEpoch}@example.com';
          const password = 'password-test-dua-perangkat-2026';
          await accountA.initialize();
          await accountB.initialize();
          expect(
            await accountA.authenticate(email, password, register: true),
            isTrue,
            reason: accountA.message,
          );
          expect(
            await accountB.authenticate(email, password, register: false),
            isTrue,
            reason: accountB.message,
          );
          final idA = await a.save(
            localTransaction(note: 'Catatan perangkat A'),
          );
          await syncA.link();
          await syncB.link();
          await syncA.synchronize();
          expect(syncA.pending, 0, reason: syncA.message);
          await syncB.synchronize();
          var rowsB = await b.list(periodStart: DateTime(2026, 10));
          expect(rowsB, hasLength(1), reason: syncB.message);
          final idB = rowsB.single.id!;
          expect(rowsB.single.note, 'Catatan perangkat A');
          await a.save(localTransaction(id: idA, note: 'Edit A'));
          await b.save(
            localTransaction(id: idB, note: 'Edit B', amount: 65000),
          );
          await syncA.synchronize();
          await syncB.synchronize();
          expect(syncB.issues, hasLength(1));
          expect(
            (await b.list(periodStart: DateTime(2026, 10))).single.note,
            'Edit B',
          );
          await syncB.resolve(syncB.issues.single.remoteId, keepLocal: true);
          await syncB.synchronize();
          await syncA.synchronize();
          expect(
            (await a.list(periodStart: DateTime(2026, 10))).single.amount,
            65000,
          );
          expect(syncA.issues, isEmpty);
          expect(syncB.pending, 0);
          // A queued deletion survives an actual SQLite close/reopen.
          await b.delete(idB);
          syncB.dispose();
          await b.close();
          b = TransactionRepository(
            factory: databaseFactoryFfiNoIsolate,
            databasePath: '${folder.path}/b.db',
          );
          syncB = TransactionSyncController(
            repository: b,
            account: accountB,
            gateway: HttpTransactionSyncGateway(baseUri: server),
          );
          await syncB.synchronize();
          await syncA.synchronize();
          expect(await a.list(periodStart: DateTime(2026, 10)), isEmpty);
          expect(syncB.pending, 0, reason: syncB.message);
          expect(syncB.binding!.lastSuccess, isNotNull);
        } finally {
          syncA.dispose();
          syncB.dispose();
          accountA.dispose();
          accountB.dispose();
          await a.close();
          await b.close();
          await folder.delete(recursive: true);
        }
      }, _RealHttp());
    },
    skip: url.isEmpty
        ? 'Set SYNC_TEST_API_URL to an isolated test backend'
        : false,
  );
}
