import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:catat_uang/auth/account_controller.dart';
import 'package:catat_uang/auth/auth_models.dart';

import 'auth_fakes.dart';

void main() {
  late FakeAuthGateway gateway;
  late MemorySessionStore store;
  late AccountController controller;
  setUp(() {
    gateway = FakeAuthGateway();
    store = MemorySessionStore();
    controller = AccountController(gateway: gateway, store: store);
  });
  tearDown(() => controller.dispose());

  test(
    'sign-in persists secure session before publishing account state',
    () async {
      await controller.initialize();
      expect(controller.canAuthenticate, isTrue);
      expect(
        await controller.authenticate(
          'test@example.com',
          'rahasia-untuk-pengujian',
          register: false,
        ),
        isTrue,
      );
      expect(store.value?.user.id, testUser.id);
      expect(controller.user?.email, testUser.email);
      expect(controller.verified, isTrue);
      expect(controller.canAuthenticate, isFalse);
    },
  );

  test('a restored session is checked with server', () async {
    store.value = testSession();
    await controller.initialize();
    expect(gateway.meCalls, 1);
    expect(controller.verified, isTrue);
  });

  test('offline restore preserves credentials as unverified', () async {
    store.value = testSession();
    gateway.meFailure = const AuthFailure('offline');
    await controller.initialize();
    expect(controller.hasSession, isTrue);
    expect(controller.verified, isFalse);
    expect(store.clears, 0);
    gateway.meFailure = null;
    await controller.refresh();
    expect(controller.verified, isTrue);
  });

  test('server 401 clears account and secure token', () async {
    store.value = testSession();
    gateway.meFailure = const AuthFailure('expired', status: 401);
    await controller.initialize();
    expect(controller.hasSession, isFalse);
    expect(store.value, isNull);
    expect(controller.message, contains('Sesi berakhir'));
  });

  test('an expired token is never sent to server', () async {
    store.value = testSession(
      expiry: DateTime.now().toUtc().subtract(const Duration(seconds: 1)),
    );
    await controller.initialize();
    expect(gateway.meCalls, 0);
    expect(store.value, isNull);
  });

  test(
    'write failure revokes new token without claiming login success',
    () async {
      store.failWrite = true;
      await controller.initialize();
      expect(
        await controller.authenticate(
          'test@example.com',
          'rahasia-untuk-pengujian',
          register: true,
        ),
        isFalse,
      );
      expect(controller.hasSession, isFalse);
      expect(gateway.logoutCalls, 1);
      expect(store.value, isNull);
    },
  );

  test(
    'unavailable storage blocks account actions until successful retry',
    () async {
      store.failRead = true;
      await controller.initialize();
      expect(controller.storageProblem, isTrue);
      expect(controller.canAuthenticate, isFalse);
      store.failRead = false;
      await controller.initialize();
      expect(controller.storageProblem, isFalse);
      expect(controller.canAuthenticate, isTrue);
    },
  );

  test(
    'offline logout clears local token and reports incomplete server revocation',
    () async {
      store.value = testSession();
      await controller.initialize();
      gateway.logoutFailure = const AuthFailure('offline');
      await controller.logout(all: true);
      expect(store.value, isNull);
      expect(controller.hasSession, isFalse);
      expect(gateway.lastLogoutAll, isTrue);
      expect(controller.message, contains('belum dapat dicabut'));
    },
  );

  test('failed deletion blocks re-login and can be retried', () async {
    store.value = testSession();
    await controller.initialize();
    store.failClear = true;
    await controller.logout();
    expect(controller.storageProblem, isTrue);
    expect(controller.canAuthenticate, isFalse);
    store.failClear = false;
    await controller.initialize();
    expect(controller.canAuthenticate, isTrue);
    expect(store.value, isNull);
  });

  test('duplicate submits do not issue duplicate registrations', () async {
    await controller.initialize();
    gateway.pendingAuthentication = Completer<AuthSession>();
    final first = controller.authenticate(
      'test@example.com',
      'rahasia-untuk-pengujian',
      register: true,
    );
    expect(
      await controller.authenticate(
        'test@example.com',
        'rahasia-untuk-pengujian',
        register: true,
      ),
      isFalse,
    );
    gateway.pendingAuthentication!.complete(testSession());
    expect(await first, isTrue);
    expect(gateway.authCalls, 1);
  });

  test('different user identity invalidates a restored token', () async {
    store.value = testSession();
    gateway.currentUser = const AuthUser(
      id: '22222222-2222-4222-8222-222222222222',
      email: 'other@example.com',
    );
    await controller.initialize();
    expect(controller.hasSession, isFalse);
    expect(store.value, isNull);
  });

  testWidgets('expiry during a pending verification cannot revive session', (
    tester,
  ) async {
    var now = DateTime.now().toUtc();
    controller.dispose();
    controller = AccountController(
      gateway: gateway,
      store: store,
      now: () => now,
    );
    store.value = testSession(expiry: now.add(const Duration(seconds: 1)));
    gateway.pendingMe = Completer<AuthUser>();
    final restore = controller.initialize();
    await tester.pump();
    now = now.add(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    gateway.pendingMe!.complete(testUser);
    await restore;
    expect(controller.hasSession, isFalse);
    expect(store.value, isNull);
  });

  testWidgets('429 blocks repeat submissions until retry deadline', (
    tester,
  ) async {
    await controller.initialize();
    gateway.authFailure = const AuthFailure(
      'retry later',
      status: 429,
      retryAfter: Duration(seconds: 2),
    );
    await controller.authenticate(
      'test@example.com',
      'rahasia-untuk-pengujian',
      register: false,
    );
    expect(controller.canAuthenticate, isFalse);
    await tester.pump(const Duration(seconds: 2));
    expect(controller.canAuthenticate, isTrue);
  });
}
