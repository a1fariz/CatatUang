import 'dart:convert';

import 'package:catat_uang/auth/account_controller.dart';
import 'package:catat_uang/auth/account_screen.dart';
import 'package:catat_uang/auth/auth_api.dart';
import 'package:catat_uang/auth/auth_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'auth_fakes.dart';

AccountSessionInfo sessionItem(int index, {bool current = false}) =>
    AccountSessionInfo(
      id: '10000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
      current: current,
      createdAt: DateTime.utc(2026, 10, 26),
      expiresAt: DateTime.utc(2026, 10, 27),
    );
Map<String, dynamic> sessionJson(AccountSessionInfo item) => {
  'id': item.id,
  'current': item.current,
  'created_at': item.createdAt.toIso8601String(),
  'expires_at': item.expiresAt.toIso8601String(),
};

void main() {
  late FakeAuthGateway gateway;
  late MemorySessionStore store;
  late AccountController account;
  setUp(() async {
    gateway = FakeAuthGateway()
      ..sessions.addAll([sessionItem(1, current: true), sessionItem(2)]);
    store = MemorySessionStore()..value = testSession();
    account = AccountController(gateway: gateway, store: store);
    await account.initialize();
  });
  tearDown(() => account.dispose());

  test('list and revoke keep current token unchanged', () async {
    final stored = store.value;
    final page = await account.listSessions();
    expect(page!.items, hasLength(2));
    expect(page.items.first.current, isTrue);
    expect(await account.revokeSession(sessionItem(1).id), isFalse);
    expect(account.hasSession, isTrue);
    expect(await account.revokeSession(sessionItem(2).id), isTrue);
    expect(gateway.sessions, hasLength(1));
    expect(identical(store.value, stored), isTrue);
    expect(store.writes, 0);
    expect(store.clears, 0);
    expect(account.hasSession, isTrue);
  });
  test(
    '404 retains current session while unauthorized listing clears it',
    () async {
      gateway.sessionsFailure = const AuthFailure(
        'Sesi tidak ada.',
        status: 404,
      );
      expect(await account.revokeSession(sessionItem(2).id), isFalse);
      expect(account.hasSession, isTrue);
      gateway.sessionsFailure = const AuthFailure(
        'Sesi berakhir.',
        status: 401,
      );
      expect(await account.listSessions(), isNull);
      expect(account.hasSession, isFalse);
      expect(store.value, isNull);
    },
  );
  test(
    'HTTP uses bounded paging and one non-redirected DELETE without body',
    () async {
      var deletes = 0;
      final api = HttpAuthGateway(
        baseUri: gateway.baseUri,
        clientFactory: () => MockClient((request) async {
          expect(request.followRedirects, isFalse);
          expect(request.headers['Authorization'], 'Bearer token');
          if (request.method == 'DELETE') {
            deletes++;
            expect(request.url.path, '/v1/auth/sessions/${sessionItem(2).id}');
            expect(request.body, isEmpty);
            return http.Response('', 204);
          }
          expect(request.url.queryParameters, {'limit': '50', 'offset': '50'});
          return http.Response(
            jsonEncode({
              'items': [sessionJson(sessionItem(2))],
              'limit': 50,
              'offset': 50,
              'has_more': false,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(api.close);
      expect((await api.listSessions('token', offset: 50)).items, hasLength(1));
      await api.revokeSession('token', sessionItem(2).id);
      expect(deletes, 1);
      await expectLater(
        api.revokeSession('token', '../logout-all'),
        throwsA(isA<AuthFailure>()),
      );
      expect(deletes, 1);
    },
  );
  test(
    'session pages reject malformed identifiers, duplicate sessions and invalid timestamps',
    () {
      final good = {
        'items': [sessionJson(sessionItem(1, current: true))],
        'limit': 50,
        'offset': 0,
        'has_more': false,
      };
      expect(AccountSessionPage.fromJson(good, 0).items, hasLength(1));
      for (final value in [
        {...good, 'offset': 0.0},
        {...good, 'offset': 1},
        {...good, 'has_more': true},
        {
          ...good,
          'items': [sessionJson(sessionItem(1)), sessionJson(sessionItem(1))],
        },
        {
          ...good,
          'items': [
            sessionJson(sessionItem(1, current: true)),
            sessionJson(sessionItem(2, current: true)),
          ],
        },
        {
          ...good,
          'items': [
            {...sessionJson(sessionItem(1)), 'id': 'not-a-session'},
          ],
        },
        {
          ...good,
          'items': [
            {
              ...sessionJson(sessionItem(1)),
              'created_at': '2026-10-26T00:00:00',
            },
          ],
        },
        {
          ...good,
          'items': [
            {
              ...sessionJson(sessionItem(1)),
              'expires_at': '2025-01-01T00:00:00Z',
            },
          ],
        },
      ]) {
        expect(
          () => AccountSessionPage.fromJson(value, 0),
          throwsFormatException,
        );
      }
    },
  );
  testWidgets(
    'session page protects current session and requires revoke confirmation',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: AccountScreen(controller: account)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Lihat sesi masuk'));
      await tester.tap(find.text('Lihat sesi masuk'));
      await tester.pumpAndSettle();
      expect(find.text('Sesi ini'), findsOneWidget);
      expect(find.text('Cabut'), findsOneWidget);
      await tester.tap(find.text('Cabut'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Batal'));
      await tester.pumpAndSettle();
      expect(gateway.sessionRevocations, 0);
      await tester.tap(find.text('Cabut'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cabut sesi'));
      await tester.pumpAndSettle();
      expect(gateway.sessionRevocations, 1);
      expect(find.text('Cabut'), findsNothing);
      expect(find.text('Sesi dicabut.'), findsOneWidget);
      expect(account.hasSession, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
