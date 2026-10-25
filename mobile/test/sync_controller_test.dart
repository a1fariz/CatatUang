import 'dart:async';

import 'package:catat_uang/auth/account_controller.dart';
import 'package:catat_uang/auth/auth_models.dart';
import 'package:catat_uang/sync/sync_controller.dart';
import 'package:catat_uang/sync/sync_models.dart';
import 'package:catat_uang/transaction_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'auth_fakes.dart';
import 'sync_fakes.dart';

void main() {
  late TransactionRepository repo;
  late FakeAuthGateway auth;
  late AccountController account;
  late FakeSyncGateway gateway;
  late TransactionSyncController sync;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    repo = TransactionRepository(
      factory: databaseFactoryFfiNoIsolate,
      databasePath: inMemoryDatabasePath,
    );
    auth = FakeAuthGateway();
    account = AccountController(
      gateway: auth,
      store: MemorySessionStore()..value = testSession(),
    );
    await account.initialize();
    gateway = FakeSyncGateway();
    sync = TransactionSyncController(
      repository: repo,
      account: account,
      gateway: gateway,
    );
    await sync.reload();
  });
  tearDown(() async {
    sync.dispose();
    account.dispose();
    await repo.close();
  });

  test('login alone does not link, pull, or upload financial data', () async {
    await repo.save(localTransaction());
    await sync.reload();
    expect(sync.binding, isNull);
    expect(gateway.pushes, 0);
    expect(gateway.pulls, 0);
    await sync.synchronize();
    expect(gateway.pushes, 0);
    expect(gateway.pulls, 0);
    await sync.link();
    expect(gateway.pushes, 0);
    expect(gateway.pulls, 0);
    expect(sync.pending, 1);
    await sync.synchronize();
    expect(sync.pending, 0);
    expect(gateway.records.length, 1);
    expect(sync.binding!.lastSuccess, isNotNull);
  });

  test(
    'lost committed response retries the exact operation before pulling its echo',
    () async {
      final id = await repo.save(localTransaction());
      await sync.link();
      gateway.loseNextResponse = true;
      await sync.synchronize();
      expect(sync.pending, 1);
      expect(gateway.changes.length, 1);
      await repo.save(
        localTransaction(id: id, amount: 99000, note: 'Edit sesudah timeout'),
      );
      await sync.synchronize();
      expect(gateway.requests[1], gateway.requests[0]);
      expect(
        gateway.requests[2]['operation_id'],
        isNot(gateway.requests[0]['operation_id']),
      );
      expect(gateway.records.values.single.version, 2);
      expect(gateway.records.values.single.json['amount_minor'], 99000);
      expect(sync.issues, isEmpty);
      expect(sync.pending, 0);
    },
  );

  test(
    'another device edit causes a conflict and requires explicit resolution',
    () async {
      final id = await repo.save(localTransaction());
      await sync.link();
      await sync.synchronize();
      final remote = gateway.records.values.single;
      await repo.save(localTransaction(id: id, note: 'Pilihan perangkat'));
      gateway.change(
        remoteRecord(id: remote.id, version: 2, note: 'Pilihan akun'),
      );
      await sync.synchronize();
      expect(sync.issues, hasLength(1));
      expect(
        (await repo.list(periodStart: DateTime(2026, 10))).single.note,
        'Pilihan perangkat',
      );
      expect(gateway.pushes, 1);
      await sync.resolve(remote.id, keepLocal: true);
      expect(sync.issues, isEmpty);
      expect(sync.pending, 1);
      await sync.synchronize();
      expect(gateway.records.values.single.version, 3);
      expect(gateway.records.values.single.json['note'], 'Pilihan perangkat');
    },
  );

  test(
    'local clearing while pull is pending never restores remote rows',
    () async {
      await sync.link();
      gateway.change(remoteRecord());
      gateway.pullGate = Completer<void>();
      final running = sync.synchronize();
      while (gateway.pulls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await repo.clearAllData();
      gateway.pullGate!.complete();
      await running;
      expect(await repo.list(periodStart: DateTime(2026, 10)), isEmpty);
      expect(await repo.syncBinding(), isNull);
      expect(await repo.syncPendingCount(), 0);
    },
  );

  test(
    'account switch never sends the previous ledger queue to a new account',
    () async {
      await repo.save(localTransaction());
      await sync.link();
      await account.logout();
      final other = AuthUser(id: syncId(), email: 'other@example.com');
      auth.issued = AuthSession(
        token: 'b' * 43,
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        user: other,
      );
      auth.currentUser = other;
      await account.authenticate(
        'other@example.com',
        'password',
        register: false,
      );
      await sync.synchronize();
      expect(gateway.pushes, 0);
      expect(gateway.pulls, 0);
      expect(sync.ownerMatches, isFalse);
      expect(sync.pending, 1);
    },
  );

  test(
    'logout during a request discards its result and preserves uncertain queue',
    () async {
      await repo.save(localTransaction());
      await sync.link();
      gateway.pushGate = Completer<void>();
      final running = sync.synchronize();
      while (gateway.pushes == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await account.logout();
      gateway.pushGate!.complete();
      await running;
      expect(sync.pending, 1);
      expect(account.hasSession, isFalse);
      expect(gateway.changes.length, 1);
    },
  );

  test(
    'invalid input stays visible and a corrected edit can be retried',
    () async {
      final id = await repo.save(localTransaction());
      await sync.link();
      gateway.pushFailure = const SyncFailure(
        'Catatan terlalu panjang.',
        status: 422,
      );
      await sync.synchronize();
      expect(sync.issues, hasLength(1));
      expect(sync.pending, 1);
      gateway.pushFailure = null;
      await repo.save(localTransaction(id: id, note: 'Diperbaiki'));
      await sync.synchronize();
      expect(sync.issues, isEmpty);
      expect(sync.pending, 0);
      expect(gateway.records.values.single.json['note'], 'Diperbaiki');
    },
  );

  test('401 invalidates only the session used for authorization', () async {
    final response = Completer<void>();
    final request = account.authorized(
      userId: testUser.id,
      server: auth.baseUri,
      action: (_) async {
        await response.future;
        throw const AuthFailure('expired', status: 401);
      },
    );
    final check = expectLater(request, throwsA(isA<AuthFailure>()));
    await account.logout();
    auth.issued = testSession();
    await account.authenticate(testUser.email, 'password', register: false);
    response.complete();
    await check;
    expect(account.hasSession, isTrue);
  });
}
