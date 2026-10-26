import 'dart:async';

import 'package:flutter/foundation.dart';

import 'auth_api.dart';
import 'auth_models.dart';
import 'session_store.dart';

class AccountController extends ChangeNotifier {
  AccountController({
    required AuthGateway gateway,
    required SessionStore store,
    DateTime Function()? now,
  }) : _gateway = gateway,
       _store = store,
       _now = now ?? DateTime.now;

  final AuthGateway _gateway;
  final SessionStore _store;
  final DateTime Function() _now;
  AuthSession? _session;
  Timer? _expiryTimer;
  Timer? _retryTimer;
  DateTime? _blockedUntil;
  bool _busy = false;
  bool _clearing = false;
  bool _disposed = false;
  bool _needsClear = false;
  bool initialized = false;
  bool verified = false;
  bool storageProblem = false;
  String? message;

  AuthUser? get user => _session?.user;
  Uri get serverUri => _gateway.baseUri;

  Future<T> authorized<T>({
    required String userId,
    required Uri server,
    required Future<T> Function(String token) action,
  }) async {
    final session = _session;
    if (_disposed ||
        busy ||
        !verified ||
        storageProblem ||
        session == null ||
        session.user.id != userId ||
        server != serverUri ||
        !session.expiresAt.isAfter(_now())) {
      throw const AuthFailure(
        'Masuk dan periksa akun pemilik catatan sebelum sinkronisasi.',
      );
    }
    try {
      final result = await action(session.token);
      if (_disposed || _session != session || busy) {
        throw const AuthFailure(
          'Sesi berubah. Hasil akan diperiksa pada sinkronisasi berikutnya.',
        );
      }
      return result;
    } on AuthFailure catch (failure) {
      if (failure.status == 401 && !_disposed && _session == session) {
        await _invalidate('Sesi berakhir. Silakan masuk kembali.');
      }
      rethrow;
    }
  }

  bool get hasSession => _session != null;
  bool get busy => _busy || _clearing;
  bool get rateLimited => _blockedUntil?.isAfter(_now()) ?? false;
  bool get canAuthenticate =>
      initialized && !busy && !storageProblem && !hasSession && !rateLimited;
  bool get canChangePassword =>
      initialized &&
      !busy &&
      !storageProblem &&
      hasSession &&
      verified &&
      !rateLimited;
  bool get canManageSessions =>
      initialized && !busy && !storageProblem && hasSession && verified;

  Future<T?> _sessionManagement<T>(
    Future<T> Function(String token) action,
  ) async {
    if (!canManageSessions || _disposed) {
      return null;
    }
    final session = _session!;
    if (!session.expiresAt.isAfter(_now())) {
      await _invalidate('Sesi berakhir. Silakan masuk kembali.');
      return null;
    }
    _busy = true;
    message = null;
    _notify();
    try {
      final result = await action(session.token);
      if (_disposed || _session != session) {
        return null;
      }
      return result;
    } on AuthFailure catch (failure) {
      if (!_disposed && _session == session) {
        if (failure.status == 401) {
          await _invalidate('Sesi berakhir. Silakan masuk kembali.');
        } else {
          message = failure.message;
        }
      }
    } catch (_) {
      if (!_disposed && _session == session) {
        message =
            'Pengelolaan sesi belum dapat dipastikan. Perbarui daftar sesi.';
      }
    } finally {
      _busy = false;
      _notify();
    }
    return null;
  }

  Future<AccountSessionPage?> listSessions({int offset = 0}) =>
      _sessionManagement(
        (token) => _gateway.listSessions(token, offset: offset),
      );
  Future<bool> revokeSession(String id) async =>
      await _sessionManagement((token) async {
        await _gateway.revokeSession(token, id);
        return true;
      }) ==
      true;

  void _acceptRateLimit(AuthFailure failure) {
    if (failure.retryAfter case final delay?) {
      _blockedUntil = _now().add(delay);
      _retryTimer?.cancel();
      _retryTimer = Timer(delay, () {
        _blockedUntil = null;
        _notify();
      });
    }
  }

  Future<bool> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    if (!canChangePassword || _disposed) return false;
    final session = _session!;
    if (!session.expiresAt.isAfter(_now())) {
      await _invalidate('Sesi berakhir. Silakan masuk kembali.');
      return false;
    }
    _busy = true;
    message = null;
    _notify();
    try {
      await _gateway.changePassword(
        session.token,
        currentPassword,
        newPassword,
      );
      if (_disposed || _session != session) return false;
      if (!session.expiresAt.isAfter(_now())) {
        await _invalidate(
          'Kata sandi diperbarui. Sesi berakhir; masuk kembali menggunakan kata sandi baru.',
        );
        return false;
      }
      return true;
    } on AuthFailure catch (failure) {
      if (_disposed || _session != session) return false;
      if (failure.status == 401) {
        await _invalidate('Sesi berakhir. Silakan masuk kembali.');
      } else {
        _acceptRateLimit(failure);
        message = failure.status == null || failure.status! >= 500
            ? 'Hasil penggantian belum dapat dipastikan. Periksa koneksi; bila perlu, coba masuk menggunakan kata sandi baru.'
            : failure.message;
      }
      return false;
    } catch (_) {
      if (!_disposed && _session == session) {
        message =
            'Hasil penggantian belum dapat dipastikan. Periksa koneksi dan coba masuk dengan kata sandi baru bila diperlukan.';
      }
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    if (_busy || _disposed || initialized && !storageProblem) return;
    _busy = true;
    message = null;
    _notify();
    try {
      if (_needsClear) {
        await _store.clear();
        _needsClear = false;
      }
      final stored = await _store.read();
      if (_disposed) return;
      storageProblem = false;
      if (stored != null) {
        if (!stored.expiresAt.isAfter(_now())) {
          await _invalidate('Sesi berakhir. Silakan masuk kembali.');
        } else {
          _session = stored;
          _armExpiry();
          await _check(stored);
        }
      }
    } on FormatException {
      await _invalidate('Sesi tersimpan tidak valid. Silakan masuk kembali.');
    } catch (_) {
      storageProblem = true;
      message = 'Penyimpanan akun tidak dapat diakses. Coba lagi.';
    } finally {
      initialized = true;
      _busy = false;
      _notify();
    }
  }

  Future<bool> authenticate(
    String email,
    String password, {
    required bool register,
  }) async {
    if (!canAuthenticate || _disposed) return false;
    _busy = true;
    message = null;
    _notify();
    AuthSession? received;
    try {
      received = await _gateway.authenticate(
        email,
        password,
        register: register,
      );
      if (_disposed) return false;
      if (!received.expiresAt.isAfter(_now())) {
        throw const AuthFailure(
          'Sesi sudah berakhir. Periksa waktu perangkat lalu masuk kembali.',
        );
      }
      try {
        await _store.write(received);
      } catch (_) {
        // A failed platform write may have partially succeeded. Never fall back
        // to plaintext storage, and try to revoke the newly issued token.
        try {
          await _gateway.logout(received.token);
        } catch (_) {
          /* No token logging. */
        }
        _needsClear = true;
        try {
          await _store.clear();
          _needsClear = false;
        } catch (_) {
          storageProblem = true;
        }
        throw const AuthFailure('Sesi gagal disimpan dengan aman. Coba lagi.');
      }
      if (_disposed) return false;
      _session = received;
      verified = true;
      _armExpiry();
      return true;
    } on AuthFailure catch (failure) {
      message = failure.message;
      _acceptRateLimit(failure);
      return false;
    } catch (_) {
      message = 'Akun belum dapat digunakan. Coba lagi.';
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> refresh() async {
    if (_disposed || busy) return;
    if (!initialized || storageProblem) {
      await initialize();
      return;
    }
    final session = _session;
    if (session == null) return;
    if (!session.expiresAt.isAfter(_now())) {
      await _invalidate('Sesi berakhir. Silakan masuk kembali.');
      return;
    }
    _busy = true;
    _notify();
    try {
      await _check(session);
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> _check(AuthSession session) async {
    try {
      final user = await _gateway.me(session.token);
      if (_disposed || _session != session) return;
      if (user.id != session.user.id) {
        await _invalidate(
          'Sesi tidak dapat diverifikasi. Silakan masuk kembali.',
        );
        return;
      }
      verified = true;
      message = null;
    } on AuthFailure catch (failure) {
      if (_disposed || _session != session) return;
      if (failure.status == 401) {
        await _invalidate('Sesi berakhir. Silakan masuk kembali.');
      } else {
        verified = false;
        message = 'Akun belum dapat diperiksa. Periksa koneksi lalu coba lagi.';
      }
    } catch (_) {
      if (_disposed || _session != session) return;
      verified = false;
      message = 'Akun belum dapat diperiksa. Periksa koneksi lalu coba lagi.';
    }
  }

  Future<void> logout({bool all = false}) async {
    if (busy || _disposed) return;
    final session = _session;
    if (session == null) return;
    _busy = true;
    _expiryTimer?.cancel();
    _notify();
    String? notice;
    try {
      await _gateway.logout(session.token, all: all);
    } on AuthFailure catch (failure) {
      if (failure.status != 401) {
        notice =
            'Keluar dari perangkat ini. Sesi server belum dapat dicabut dan akan berakhir sesuai masa berlakunya.';
      } else if (all) {
        notice =
            'Sesi ini sudah berakhir. Sesi perangkat lain belum dapat dicabut.';
      }
    } catch (_) {
      notice =
          'Keluar dari perangkat ini. Sesi server belum dapat dicabut dan akan berakhir sesuai masa berlakunya.';
    }
    try {
      await _invalidate(notice);
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> _invalidate(String? notice) async {
    _session = null;
    verified = false;
    message = notice;
    _expiryTimer?.cancel();
    _clearing = true;
    _needsClear = true;
    _notify();
    try {
      await _store.clear();
      _needsClear = false;
      storageProblem = false;
    } catch (_) {
      storageProblem = true;
      message = 'Sesi belum dapat dibersihkan dari perangkat. Coba lagi.';
    } finally {
      _clearing = false;
      _notify();
    }
  }

  void _armExpiry() {
    _expiryTimer?.cancel();
    final session = _session;
    if (session == null) return;
    final remaining = session.expiresAt.difference(_now());
    _expiryTimer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      if (!_disposed && _session == session) {
        unawaited(_invalidate('Sesi berakhir. Silakan masuk kembali.'));
      }
    });
  }

  void clearMessage() {
    if (!busy) {
      message = null;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _expiryTimer?.cancel();
    _retryTimer?.cancel();
    _gateway.close();
    super.dispose();
  }
}
