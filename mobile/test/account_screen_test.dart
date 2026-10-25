import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:catat_uang/auth/account_controller.dart';
import 'package:catat_uang/auth/account_screen.dart';
import 'package:catat_uang/auth/auth_models.dart';
import 'package:catat_uang/main.dart';
import 'package:catat_uang/reminder_service.dart';
import 'package:catat_uang/transaction.dart';
import 'package:catat_uang/transaction_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'auth_fakes.dart';

class _SilentReminders extends ReminderService {
  @override
  Future<List<int>> pendingIds() async => [];
  @override
  Future<void> cancelAll() async {}
}

void main() {
  testWidgets('validates login and registration before contacting server', (
    tester,
  ) async {
    final gateway = FakeAuthGateway();
    final controller = AccountController(
      gateway: gateway,
      store: MemorySessionStore(),
    );
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(home: AccountScreen(controller: controller)),
    );
    await tester.ensureVisible(find.byKey(const Key('auth_submit')));
    await tester.tap(find.byKey(const Key('auth_submit')));
    await tester.pumpAndSettle();
    expect(find.text('Masukkan alamat email yang valid.'), findsOneWidget);
    expect(gateway.authCalls, 0);
    await tester.ensureVisible(find.text('Belum punya akun? Daftar'));
    await tester.tap(find.text('Belum punya akun? Daftar'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'test@example.com',
    );
    await tester.enterText(
      find.byType(TextFormField).at(1),
      'password-untuk-testing',
    );
    await tester.enterText(
      find.byType(TextFormField).at(2),
      'password-lainnya',
    );
    await tester.ensureVisible(find.byKey(const Key('auth_submit')));
    await tester.tap(find.byKey(const Key('auth_submit')));
    await tester.pumpAndSettle();
    expect(find.text('Kata sandi belum sama.'), findsOneWidget);
    expect(gateway.authCalls, 0);
    await tester.enterText(
      find.byType(TextFormField).at(2),
      'password-untuk-testing',
    );
    await tester.ensureVisible(find.byKey(const Key('auth_submit')));
    await tester.tap(find.byKey(const Key('auth_submit')));
    await tester.pumpAndSettle();
    expect(find.text(testUser.email), findsOneWidget);
    expect(gateway.lastRegistration, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('credentials errors remain on form and permit correction', (
    tester,
  ) async {
    final gateway = FakeAuthGateway()
      ..authFailure = const AuthFailure(
        'Email atau kata sandi tidak cocok.',
        status: 401,
      );
    final controller = AccountController(
      gateway: gateway,
      store: MemorySessionStore(),
    );
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(home: AccountScreen(controller: controller)),
    );
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'test@example.com',
    );
    await tester.enterText(
      find.byType(TextFormField).at(1),
      'password-untuk-testing',
    );
    await tester.ensureVisible(find.byKey(const Key('auth_submit')));
    await tester.tap(find.byKey(const Key('auth_submit')));
    await tester.pumpAndSettle();
    expect(find.text('Email atau kata sandi tidak cocok.'), findsOneWidget);
    expect(controller.hasSession, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('login and logout through settings retain local transaction', (
    tester,
  ) async {
    sqfliteFfiInit();
    final repository = TransactionRepository(
      factory: databaseFactoryFfiNoIsolate,
      databasePath: inMemoryDatabasePath,
    );
    final gateway = FakeAuthGateway();
    final store = MemorySessionStore();
    final controller = AccountController(gateway: gateway, store: store);
    await repository.save(
      MoneyTransaction(
        id: null,
        type: TransactionType.expense,
        amount: 42000,
        category: 'Makan',
        occurredAt: DateTime.now(),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          repository: repository,
          onSettingsChanged: (_) {},
          reminders: _SilentReminders(),
          account: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pengaturan').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Akun'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'test@example.com',
    );
    await tester.enterText(
      find.byType(TextFormField).at(1),
      'password-untuk-testing',
    );
    await tester.ensureVisible(find.byKey(const Key('auth_submit')));
    await tester.tap(find.byKey(const Key('auth_submit')));
    await tester.pumpAndSettle();
    expect(find.text(testUser.email), findsOneWidget);
    await tester.ensureVisible(find.text('Keluar dari akun'));
    await tester.tap(find.text('Keluar dari akun'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keluar'));
    await tester.pumpAndSettle();
    expect(store.value, isNull);
    expect(await repository.hasEntries(), isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Catatan').last);
    await tester.pumpAndSettle();
    expect(find.text('Makan'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await repository.close();
  });
}
