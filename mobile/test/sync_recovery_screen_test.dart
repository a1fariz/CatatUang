import 'package:catat_uang/auth/account_controller.dart';
import 'package:catat_uang/sync/sync_card.dart';
import 'package:catat_uang/sync/sync_controller.dart';
import 'package:catat_uang/sync/sync_models.dart';
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
    await repo.save(localTransaction(note: 'Pilihan perangkat'));
    await sync.link();
    await sync.synchronize();
    final id = gateway.records.keys.single;
    gateway.currentDataset = syncId();
    gateway.changes.clear();
    gateway.records.clear();
    gateway.receipts.clear();
    gateway.change(remoteRecord(id: id, note: 'Pilihan akun'));
    await sync.synchronize();
  });
  tearDown(() async {
    sync.dispose();
    account.dispose();
    await repo.close();
  });
  testWidgets(
    'review needs an explicit choice and confirmation before changing local data',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(children: [TransactionSyncCard(controller: sync)]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tinjau pemulihan'));
      await tester.pumpAndSettle();
      expect(find.text('Tinjau pemulihan transaksi'), findsOneWidget);
      final apply = find.widgetWithText(FilledButton, 'Terapkan pemulihan');
      expect(tester.widget<FilledButton>(apply).onPressed, isNull);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Gunakan data akun'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Batal'));
      await tester.pumpAndSettle();
      expect(await repo.recoveryBackups(), isEmpty);
      expect(
        (await repo.list(periodStart: DateTime(2026, 10))).single.note,
        'Pilihan perangkat',
      );
      await tester.tap(apply);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Terapkan pilihan'));
      await tester.pumpAndSettle();
      expect(
        (await repo.list(periodStart: DateTime(2026, 10))).single.note,
        'Pilihan akun',
      );
      expect(find.text('Cadangan transaksi lokal'), findsOneWidget);
      expect(gateway.pushes, 1);
      await tester.tap(find.text('Cadangan transaksi lokal'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SimpleDialogOption).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pulihkan cadangan'));
      await tester.pumpAndSettle();
      expect(
        (await repo.list(periodStart: DateTime(2026, 10))).single.note,
        'Pilihan perangkat',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
