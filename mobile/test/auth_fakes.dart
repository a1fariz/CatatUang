import 'dart:async';

import 'package:catat_uang/auth/auth_api.dart';
import 'package:catat_uang/auth/auth_models.dart';
import 'package:catat_uang/auth/session_store.dart';

const testUser = AuthUser(
  id: '11111111-1111-4111-8111-111111111111',
  email: 'test@example.com',
);
AuthSession testSession({DateTime? expiry}) => AuthSession(
  token: 'a' * 43,
  expiresAt: expiry ?? DateTime.now().toUtc().add(const Duration(hours: 24)),
  user: testUser,
);

class MemorySessionStore implements SessionStore {
  AuthSession? value;
  bool failRead = false;
  bool failWrite = false;
  bool failClear = false;
  int writes = 0;
  int clears = 0;
  @override
  Future<AuthSession?> read() async {
    if (failRead) throw StateError('storage unavailable');
    return value;
  }

  @override
  Future<void> write(AuthSession session) async {
    writes++;
    if (failWrite) throw StateError('storage unavailable');
    value = session;
  }

  @override
  Future<void> clear() async {
    clears++;
    if (failClear) throw StateError('storage unavailable');
    value = null;
  }
}

class FakeAuthGateway implements AuthGateway {
  @override
  Uri get baseUri => Uri.parse('https://api.example.com/');
  AuthFailure? authFailure;
  AuthFailure? meFailure;
  AuthFailure? logoutFailure;
  AuthSession? issued;
  AuthUser currentUser = testUser;
  Completer<AuthSession>? pendingAuthentication;
  Completer<AuthUser>? pendingMe;
  int authCalls = 0;
  int meCalls = 0;
  int logoutCalls = 0;
  bool? lastRegistration;
  bool? lastLogoutAll;
  bool closed = false;
  @override
  Future<AuthSession> authenticate(
    String email,
    String password, {
    required bool register,
  }) async {
    authCalls++;
    lastRegistration = register;
    if (authFailure case final failure?) throw failure;
    return pendingAuthentication?.future ?? issued ?? testSession();
  }

  @override
  Future<AuthUser> me(String token) async {
    meCalls++;
    if (meFailure case final failure?) throw failure;
    return pendingMe?.future ?? currentUser;
  }

  @override
  Future<void> logout(String token, {bool all = false}) async {
    logoutCalls++;
    lastLogoutAll = all;
    if (logoutFailure case final failure?) throw failure;
  }

  @override
  void close() {
    closed = true;
  }
}
