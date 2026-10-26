import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:catat_uang/auth/account_controller.dart';
import 'package:catat_uang/auth/auth_api.dart';
import 'package:catat_uang/auth/auth_models.dart';
import 'package:catat_uang/auth/recovery_screen.dart';
import 'auth_fakes.dart';

class RecoveryFake implements AccountRecoveryGateway {
  int requests = 0, confirmations = 0;
  String? password;
  Completer<void>? pending;
  AuthFailure? failure;
  @override
  Future<void> requestPasswordReset(String email) async {
    requests++;
    if (failure != null) throw failure!;
  }

  @override
  Future<void> confirmPasswordReset(String token, String password) async {
    confirmations++;
    this.password = password;
    if (pending != null) await pending!.future;
    if (failure != null) throw failure!;
  }

  @override
  Future<void> requestEmailVerification(String session) async {
    requests++;
    if (failure != null) throw failure!;
  }

  @override
  Future<void> confirmEmailVerification(String token) async {
    confirmations++;
    if (failure != null) throw failure!;
  }

  @override
  void close() {}
}

void main() {
  test(
    'email actions use POST body codes, exact status and no redirects',
    () async {
      final paths = <String>[];
      final code = 'x' * 43;
      final api = HttpAuthGateway(
        baseUri: Uri.parse('https://api.example.com/'),
        clientFactory: () => MockClient((request) async {
          paths.add(request.url.path);
          expect(request.method, 'POST');
          expect(request.followRedirects, isFalse);
          expect(request.url.query, isEmpty);
          if (request.url.path.endsWith('/confirm')) {
            expect((jsonDecode(request.body) as Map)['token'], code);
          }
          if (request.url.path.endsWith('email-verification/request')) {
            expect(request.headers['authorization'], 'Bearer session');
          }
          return request.url.path.endsWith('/request')
              ? http.Response(
                  '{"message":"generic"}',
                  202,
                  headers: {'content-type': 'application/json'},
                )
              : http.Response('', 204);
        }),
      );
      await api.requestPasswordReset('test@example.com');
      await api.confirmPasswordReset(code, 'password-baru-pengujian-2026');
      await api.requestEmailVerification('session');
      await api.confirmEmailVerification(code);
      expect(paths, hasLength(4));
      api.close();
      final bad = HttpAuthGateway(
        baseUri: Uri.parse('https://api.example.com/'),
        clientFactory: () => MockClient(
          (_) async => http.Response(
            '{}',
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      await expectLater(
        bad.confirmEmailVerification(code),
        throwsA(isA<AuthFailure>()),
      );
      bad.close();
    },
  );
  testWidgets(
    'reset validates input, blocks duplicate submit and clears secrets',
    (tester) async {
      final account = AccountController(
        gateway: FakeAuthGateway(),
        store: MemorySessionStore(),
      );
      await account.initialize();
      final gateway = RecoveryFake();
      await tester.pumpWidget(
        MaterialApp(
          home: AccountRecoveryScreen(controller: account, gateway: gateway),
        ),
      );
      await tester.tap(find.text('Kirim kode email'));
      await tester.pump();
      expect(gateway.requests, 0);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'test@example.com');
      await tester.tap(find.text('Kirim kode email'));
      await tester.pumpAndSettle();
      expect(gateway.requests, 1);
      await tester.enterText(fields.at(1), 'x' * 43);
      await tester.enterText(fields.at(2), 'password-baru-pengujian-2026');
      await tester.enterText(fields.at(3), 'berbeda');
      await tester.ensureVisible(find.text('Reset kata sandi'));
      await tester.tap(find.text('Reset kata sandi'));
      await tester.pump();
      expect(gateway.confirmations, 0);
      await tester.enterText(fields.at(3), 'password-baru-pengujian-2026');
      gateway.pending = Completer<void>();
      await tester.tap(find.text('Reset kata sandi'));
      await tester.pump();
      await tester.tap(find.text('Reset kata sandi'));
      expect(gateway.confirmations, 1);
      gateway.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('semua sesi dicabut'), findsOneWidget);
      for (final index in [1, 2, 3]) {
        expect(
          tester.widget<TextField>(fields.at(index)).controller!.text,
          isEmpty,
        );
      }
      expect(account.hasSession, isFalse);
      account.dispose();
    },
  );
  testWidgets(
    'verification uses current account and refreshes verified status',
    (tester) async {
      final auth = FakeAuthGateway();
      final account = AccountController(
        gateway: auth,
        store: MemorySessionStore(),
      );
      await account.initialize();
      await account.authenticate(
        testUser.email,
        'password-pengujian-panjang',
        register: false,
      );
      final gateway = RecoveryFake();
      await tester.pumpWidget(
        MaterialApp(
          home: AccountRecoveryScreen(
            controller: account,
            verifyEmail: true,
            gateway: gateway,
          ),
        ),
      );
      await tester.tap(find.text('Kirim kode email'));
      await tester.pumpAndSettle();
      expect(gateway.requests, 1);
      auth.currentUser = AuthUser(
        id: testUser.id,
        email: testUser.email,
        emailVerified: true,
      );
      await tester.enterText(find.byType(TextField).at(1), 'x' * 43);
      await tester.tap(find.text('Verifikasi kode'));
      await tester.pumpAndSettle();
      expect(account.user!.emailVerified, isTrue);
      expect(find.text('Email terverifikasi.'), findsOneWidget);
      account.dispose();
    },
  );
}
