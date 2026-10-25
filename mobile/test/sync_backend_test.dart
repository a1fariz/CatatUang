import 'dart:io';

import 'package:catat_uang/auth/account_controller.dart';
import 'package:catat_uang/auth/auth_api.dart';
import 'package:catat_uang/auth/auth_models.dart';
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
          final rotateExecutable = Platform.environment['SYNC_TEST_ROTATE_EXE'];
          if (rotateExecutable != null && rotateExecutable.isNotEmpty) {
            await a.save(localTransaction(note: 'Sebelum rotasi dataset'));
            await syncA.synchronize();
            await syncB.synchronize();
            final before = (await b.list(
              periodStart: DateTime(2026, 10),
            )).single;
            await b.save(
              localTransaction(
                id: before.id,
                note: 'Pilihan setelah pemulihan',
                amount: 88000,
              ),
            );
            final rotated = await Process.run(rotateExecutable, [
              'rotate-after-restore',
            ]);
            expect(
              rotated.exitCode,
              0,
              reason: 'Isolated dataset rotation failed',
            );
            await syncB.synchronize();
            expect(syncB.resetRequired, isTrue);
            final planB = (await syncB.prepareRecovery())!;
            for (final item in planB.items) {
              item.keepLocal = true;
            }
            expect(
              await syncB.applyRecovery(planB),
              isTrue,
              reason: syncB.message,
            );
            await syncB.synchronize();
            expect(syncB.pending, 0, reason: syncB.message);
            await syncA.synchronize();
            expect(syncA.resetRequired, isTrue);
            final planA = (await syncA.prepareRecovery())!;
            for (final item in planA.items) {
              item.keepLocal = false;
            }
            expect(
              await syncA.applyRecovery(planA),
              isTrue,
              reason: syncA.message,
            );
            final recovered = await a.list(periodStart: DateTime(2026, 10));
            expect(recovered, hasLength(1));
            expect(recovered.single.note, 'Pilihan setelah pemulihan');
            expect(recovered.single.amount, 88000);
            expect(syncA.backups, hasLength(1));
            expect(syncB.backups, hasLength(1));
          }
          final localBefore = await a.recoverySnapshot();
          final otherBefore = await b.recoverySnapshot();
          const changedPassword = 'kata-sandi-baru-dua-perangkat-2026';
          expect(
            await accountA.changePassword(password, changedPassword),
            isTrue,
            reason: accountA.message,
          );
          expect(accountA.hasSession, isTrue);
          await accountB.refresh();
          expect(accountB.hasSession, isFalse);
          expect(await a.recoverySnapshot(), localBefore);
          expect(await b.recoverySnapshot(), otherBefore);
          final verifier = HttpAuthGateway(baseUri: server);
          try {
            await expectLater(
              verifier.authenticate(email, password, register: false),
              throwsA(
                isA<AuthFailure>().having(
                  (failure) => failure.status,
                  'status',
                  401,
                ),
              ),
            );
            expect(
              (await verifier.authenticate(
                email,
                changedPassword,
                register: false,
              )).user.id,
              accountA.user!.id,
            );
          } finally {
            verifier.close();
          }
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
