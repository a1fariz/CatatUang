import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'package:catat_uang/auth/account_controller.dart';
import 'package:catat_uang/auth/auth_api.dart';
import 'package:catat_uang/auth/auth_models.dart';
import 'package:catat_uang/auth/session_store.dart';
import 'package:catat_uang/main.dart';
import 'package:catat_uang/reminder_service.dart';
import 'package:catat_uang/transaction.dart';
import 'package:catat_uang/transaction_repository.dart';

class _NoReminders extends ReminderService {
  @override
  Future<List<int>> pendingIds() async => [];
  @override
  Future<void> cancelAll() async {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('AUTH_TEST_API_URL');

  testWidgets(
    'native secure session, backend login and logout preserve local finance',
    (tester) async {
      final server = configuredApiUri(url)!;
      final store = SecureSessionStore(server: server);
      final databasePath = path.join(
        await getDatabasesPath(),
        'auth_integration_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      final repository = TransactionRepository(databasePath: databasePath);
      var account = AccountController(
        gateway: HttpAuthGateway(baseUri: server),
        store: store,
      );
      final probe = HttpAuthGateway(baseUri: server);
      final email =
          'mobile_${DateTime.now().microsecondsSinceEpoch}@example.invalid';
      const password = 'Integration-passphrase-2026';

      Future<void> openAccount() async {
        await tester.tap(find.text('Pengaturan').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Akun'));
        await tester.pumpAndSettle();
      }

      Future<void> submitCredentials({required bool register}) async {
        if (register) {
          await tester.ensureVisible(find.text('Belum punya akun? Daftar'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Belum punya akun? Daftar'));
          await tester.pumpAndSettle();
        }
        await tester.enterText(find.byType(TextFormField).at(0), email);
        await tester.enterText(find.byType(TextFormField).at(1), password);
        if (register) {
          await tester.enterText(find.byType(TextFormField).at(2), password);
        }
        await tester.ensureVisible(find.byKey(const Key('auth_submit')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('auth_submit')));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
      }

      try {
        await store.clear();
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
              reminders: _NoReminders(),
              account: account,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await openAccount();
        await submitCredentials(register: true);
        expect(account.user?.email, email);
        expect(account.verified, isTrue);

        // Recreate both adapters: this exercises Android's actual Keystore-backed
        // plugin rather than an in-memory mock.
        final saved = await SecureSessionStore(server: server).read();
        expect(saved?.user.email, email);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        account.dispose();
        account = AccountController(
          gateway: HttpAuthGateway(baseUri: server),
          store: SecureSessionStore(server: server),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: HomeScreen(
              repository: repository,
              onSettingsChanged: (_) {},
              reminders: _NoReminders(),
              account: account,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await openAccount();
        expect(account.user?.email, email);
        expect(account.verified, isTrue);

        // A token revoked by another client must not remain an active UI session.
        await probe.logout(saved!.token);
        await account.refresh();
        await tester.pumpAndSettle();
        expect(account.hasSession, isFalse);
        expect(await store.read(), isNull);
        expect(
          find.text('Sesi berakhir. Silakan masuk kembali.'),
          findsOneWidget,
        );

        await submitCredentials(register: false);
        final active = await store.read();
        expect(active, isNotNull);
        await tester.scrollUntilVisible(
          find.text('Keluar dari akun').hitTestable(),
          200,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Keluar dari akun'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Keluar'));
        await tester.pumpAndSettle();
        expect(account.hasSession, isFalse);
        expect(await store.read(), isNull);
        await expectLater(
          probe.me(active!.token),
          throwsA(
            isA<AuthFailure>().having(
              (failure) => failure.status,
              'status',
              401,
            ),
          ),
        );
        expect(await repository.hasEntries(), isTrue);
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Catatan').last);
        await tester.pumpAndSettle();
        expect(find.text('Makan'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        account.dispose();
        probe.close();
        await store.clear();
        await repository.close();
        await deleteDatabase(databasePath);
      }
    },
    skip: url.isEmpty,
  );
}
