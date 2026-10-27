import 'dart:io';
import 'package:catat_uang/auth/account_controller.dart';
import 'package:catat_uang/main.dart';
import 'package:catat_uang/sync/sync_controller.dart';
import 'package:catat_uang/sync/sync_status_notice.dart';
import 'package:catat_uang/transaction_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'auth_fakes.dart';
import 'sync_fakes.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  testWidgets('ledger stays scrollable on phone viewport with keyboard inset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(411, 731);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = TransactionRepository(
      factory: databaseFactoryFfiNoIsolate,
      databasePath: inMemoryDatabasePath,
    );
    addTearDown(repo.close);
    await repo.save(localTransaction());
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(411, 731),
            viewInsets: EdgeInsets.only(bottom: 320),
            textScaler: TextScaler.linear(1.3),
          ),
          child: TransactionsScreen(repository: repo),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(CustomScrollView), findsOneWidget);
  });
  test(
    'demo seed is isolated, atomic and does not duplicate after reopen/clear',
    () async {
      final folder = await Directory.systemTemp.createTemp('catatuang-demo-');
      final repo = TransactionRepository(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: path.join(folder.path, 'catat_uang_demo.db'),
      );
      try {
        final now = DateTime(2026, 10, 28);
        expect(await repo.seedDemoData(now), isTrue);
        expect(await repo.list(periodStart: DateTime(2026, 10)), hasLength(8));
        expect(await repo.listBills(), hasLength(1));
        expect((await repo.billRecoverySnapshot())['bills'], hasLength(2));
        expect(
          (await repo.billRecoverySnapshot())['bill_payments'],
          hasLength(1),
        );
        await repo.close();
        expect(await repo.seedDemoData(now), isFalse);
        expect(await repo.list(periodStart: DateTime(2026, 10)), hasLength(8));
        await repo.clearAllData();
        expect(await repo.seedDemoData(now), isFalse);
        expect(await repo.hasEntries(), isFalse);
        final regular = TransactionRepository(
          factory: databaseFactoryFfiNoIsolate,
          databasePath: path.join(folder.path, 'regular.db'),
        );
        try {
          await expectLater(regular.seedDemoData(now), throwsStateError);
          expect(await regular.hasEntries(), isFalse);
        } finally {
          await regular.close();
        }
      } finally {
        await repo.close();
        await folder.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'first entry explains offline use and opens the transaction form',
    (tester) async {
      final repo = TransactionRepository(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: inMemoryDatabasePath,
      );
      addTearDown(repo.close);
      await tester.pumpWidget(
        MaterialApp(home: TransactionsScreen(repository: repo)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Mulai dari satu catatan'), findsOneWidget);
      expect(
        find.text('Bisa digunakan tanpa internet dan tanpa akun.'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Catat transaksi pertama'));
      await tester.tap(find.text('Catat transaksi pertama'));
      await tester.pumpAndSettle();
      expect(find.byType(TransactionForm), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sync notice distinguishes unlinked, pending, blocked and empty queue',
    (tester) async {
      final repo = TransactionRepository(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: inMemoryDatabasePath,
      );
      final account = AccountController(
        gateway: FakeAuthGateway(),
        store: MemorySessionStore()..value = testSession(),
      );
      await account.initialize();
      final sync = TransactionSyncController(
        repository: repo,
        account: account,
        gateway: FakeSyncGateway(),
      );
      addTearDown(() async {
        sync.dispose();
        account.dispose();
        await repo.close();
      });
      await sync.reload();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SyncStatusNotice(controller: sync)),
        ),
      );
      expect(find.text('Tersimpan di perangkat'), findsOneWidget);
      await repo.save(localTransaction());
      await sync.link();
      await tester.pumpAndSettle();
      expect(find.text('1 perubahan transaksi menunggu'), findsOneWidget);
      await sync.synchronize();
      await tester.pumpAndSettle();
      expect(find.text('Antrean transaksi kosong'), findsOneWidget);
      expect(
        find.textContaining(
          'Data akun baru diperiksa saat sinkronisasi manual.',
        ),
        findsOneWidget,
      );
      await account.logout();
      await tester.pumpAndSettle();
      expect(find.text('Sinkronisasi menunggu akun'), findsOneWidget);
    },
  );
}
