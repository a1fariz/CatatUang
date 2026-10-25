import 'package:catat_uang/auth/account_controller.dart';
import 'package:catat_uang/sync/sync_card.dart';
import 'package:catat_uang/sync/sync_controller.dart';
import 'package:catat_uang/transaction_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'auth_fakes.dart';
import 'sync_fakes.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late TransactionRepository repo;
  late AccountController account;
  late TransactionSyncController sync;
  late FakeSyncGateway gateway;
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
    await sync.reload();
  });
  tearDown(() async {
    sync.dispose();
    account.dispose();
    await repo.close();
  });

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(children: [TransactionSyncCard(controller: sync)]),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'link consent can be cancelled and linking alone does not upload',
    (tester) async {
      await repo.save(localTransaction());
      await show(tester);
      await tester.tap(find.text('Tautkan transaksi'));
      await tester.pumpAndSettle();
      expect(find.textContaining(testUser.email), findsOneWidget);
      await tester.tap(find.text('Batal'));
      await tester.pumpAndSettle();
      expect(await repo.syncBinding(), isNull);
      expect(gateway.pushes, 0);
      await tester.tap(find.text('Tautkan transaksi'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Tautkan transaksi'));
      await tester.pumpAndSettle();
      expect(await repo.syncBinding(), isNotNull);
      expect(gateway.pushes, 0);
      await tester.tap(find.text('Sinkronkan sekarang'));
      await tester.pumpAndSettle();
      expect(gateway.records, hasLength(1));
      expect(sync.pending, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'conflict dialog preserves local content until a choice is confirmed',
    (tester) async {
      final id = await repo.save(localTransaction());
      await sync.link();
      await sync.synchronize();
      final remote = gateway.records.values.single;
      await repo.save(localTransaction(id: id, note: 'Isi perangkat'));
      gateway.change(remoteRecord(id: remote.id, version: 2, note: 'Isi akun'));
      await sync.synchronize();
      await show(tester);
      await tester.tap(
        find.text('Catatan di akun dan perangkat sama-sama berubah.'),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Isi perangkat'), findsWidgets);
      expect(find.textContaining('Isi akun'), findsOneWidget);
      await tester.tap(find.text('Batal'));
      await tester.pumpAndSettle();
      expect(sync.issues, hasLength(1));
      await tester.tap(
        find.text('Catatan di akun dan perangkat sama-sama berubah.'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gunakan data akun'));
      await tester.pumpAndSettle();
      expect(sync.issues, isEmpty);
      expect(
        (await repo.list(periodStart: DateTime(2026, 10))).single.note,
        'Isi akun',
      );
      expect(gateway.pushes, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
