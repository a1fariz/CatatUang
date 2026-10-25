import 'dart:async';
import 'dart:convert';

import 'package:catat_uang/auth/account_controller.dart';
import 'package:catat_uang/auth/auth_api.dart';
import 'package:catat_uang/auth/auth_models.dart';
import 'package:catat_uang/auth/account_screen.dart';
import 'package:catat_uang/auth/password_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'auth_fakes.dart';

const oldPassword = 'kata-sandi-lama-pengujian';
const newPassword = 'kata-sandi-baru-pengujian';

void main() {
  late FakeAuthGateway gateway;
  late MemorySessionStore store;
  late AccountController account;
  setUp(() async {
    gateway = FakeAuthGateway();
    store = MemorySessionStore()..value = testSession();
    account = AccountController(gateway: gateway, store: store);
    await account.initialize();
  });
  tearDown(() => account.dispose());
  test(
    'unexpected success status is an uncertain outcome instead of password-change success',
    () async {
      final api = HttpAuthGateway(
        baseUri: gateway.baseUri,
        clientFactory: () => MockClient(
          (_) async => http.Response(
            '{}',
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.changePassword('token', oldPassword, newPassword),
        throwsA(isA<AuthFailure>()),
      );
    },
  );

  test(
    'password change keeps secure token and expiry without rewriting storage',
    () async {
      final stored = store.value;
      expect(await account.changePassword(oldPassword, newPassword), isTrue);
      expect(identical(store.value, stored), isTrue);
      expect(store.writes, 0);
      expect(store.clears, 0);
      expect(account.hasSession, isTrue);
      expect(account.verified, isTrue);
      expect(gateway.passwordChanges, 1);
    },
  );
  test('incorrect password preserves session and 401 clears it', () async {
    gateway.passwordFailure = const AuthFailure(
      'Periksa kata sandi lama.',
      status: 422,
    );
    expect(await account.changePassword(oldPassword, newPassword), isFalse);
    expect(account.hasSession, isTrue);
    gateway.passwordFailure = const AuthFailure('Sesi berakhir.', status: 401);
    expect(await account.changePassword(oldPassword, newPassword), isFalse);
    expect(account.hasSession, isFalse);
    expect(store.value, isNull);
  });
  test(
    'uncertain response is never retried and rate limit disables another attempt',
    () async {
      gateway.passwordFailure = const AuthFailure('network');
      expect(await account.changePassword(oldPassword, newPassword), isFalse);
      expect(account.message, contains('belum dapat dipastikan'));
      expect(gateway.passwordChanges, 1);
      gateway.passwordFailure = const AuthFailure(
        'Coba lagi nanti.',
        status: 429,
        retryAfter: Duration(minutes: 15),
      );
      expect(await account.changePassword(oldPassword, newPassword), isFalse);
      expect(account.rateLimited, isTrue);
      expect(await account.changePassword(oldPassword, newPassword), isFalse);
      expect(gateway.passwordChanges, 2);
    },
  );
  test(
    'duplicate submits are blocked and expired sessions cannot be revived',
    () async {
      var now = DateTime.now().toUtc();
      final expiring = AccountController(
        gateway: gateway,
        store: MemorySessionStore()
          ..value = testSession(expiry: now.add(const Duration(hours: 1))),
        now: () => now,
      );
      addTearDown(expiring.dispose);
      await expiring.initialize();
      gateway.pendingPasswordChange = Completer<void>();
      final changing = expiring.changePassword(oldPassword, newPassword);
      expect(await expiring.changePassword(oldPassword, newPassword), isFalse);
      expect(gateway.passwordChanges, 1);
      now = now.add(const Duration(hours: 2));
      await expiring.refresh();
      // refresh is busy while the POST runs; the response must not extend expiry.
      gateway.pendingPasswordChange!.complete();
      await changing;
      await expiring.refresh();
      expect(expiring.hasSession, isFalse);
    },
  );
  test(
    'HTTP password mutation uses Bearer, exact JSON and one non-redirected POST',
    () async {
      var calls = 0;
      final api = HttpAuthGateway(
        baseUri: gateway.baseUri,
        clientFactory: () => MockClient((request) async {
          calls++;
          expect(request.method, 'POST');
          expect(request.url.path, '/v1/auth/change-password');
          expect(request.followRedirects, isFalse);
          expect(request.headers['Authorization'], 'Bearer token');
          expect(jsonDecode(request.body), {
            'current_password': oldPassword,
            'new_password': newPassword,
          });
          return http.Response('', 204);
        }),
      );
      addTearDown(api.close);
      await api.changePassword('token', oldPassword, newPassword);
      expect(calls, 1);
    },
  );
  testWidgets(
    'form validates confirmation and clears secrets after failed submission',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ChangePasswordScreen(controller: account)),
      );
      await tester.pumpAndSettle();
      final fields = find.byType(TextFormField);
      await tester.tap(find.text('Simpan kata sandi baru'));
      await tester.pumpAndSettle();
      expect(gateway.passwordChanges, 0);
      await tester.enterText(fields.at(0), oldPassword);
      await tester.enterText(fields.at(1), newPassword);
      await tester.enterText(fields.at(2), 'berbeda');
      await tester.ensureVisible(find.text('Simpan kata sandi baru'));
      await tester.tap(find.text('Simpan kata sandi baru'));
      await tester.pumpAndSettle();
      expect(find.text('Kata sandi belum sama.'), findsOneWidget);
      expect(gateway.passwordChanges, 0);
      await tester.enterText(fields.at(2), newPassword);
      gateway.passwordFailure = const AuthFailure(
        'Kata sandi lama salah.',
        status: 422,
      );
      await tester.ensureVisible(find.text('Simpan kata sandi baru'));
      await tester.tap(find.text('Simpan kata sandi baru'));
      await tester.pumpAndSettle();
      expect(find.text('Kata sandi lama salah.'), findsOneWidget);
      for (final field in tester.widgetList<TextFormField>(fields)) {
        expect(field.controller!.text, isEmpty);
      }
      expect(account.hasSession, isTrue);
    },
  );
  testWidgets(
    'account opens the password form and reports success without logging out',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: AccountScreen(controller: account)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ganti kata sandi'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), oldPassword);
      await tester.enterText(fields.at(1), newPassword);
      await tester.enterText(fields.at(2), newPassword);
      await tester.ensureVisible(find.text('Simpan kata sandi baru'));
      await tester.tap(find.text('Simpan kata sandi baru'));
      await tester.pumpAndSettle();
      expect(account.hasSession, isTrue);
      expect(gateway.passwordChanges, 1);
      expect(
        find.text('Kata sandi diperbarui. Perangkat lain perlu masuk kembali.'),
        findsOneWidget,
      );
    },
  );
}
