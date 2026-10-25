import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth_models.dart';

Uri? configuredApiUri(String value, {bool allowLocalHttp = kDebugMode}) {
  if (value.trim().isEmpty) return null;
  final uri = Uri.tryParse(value.trim());
  final local =
      uri != null &&
      const {
        'localhost',
        '127.0.0.1',
        '10.0.2.2',
        '[::1]',
        '::1',
      }.contains(uri.host);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.port < 1 ||
      uri.port > 65535 ||
      !(uri.scheme == 'https' ||
          allowLocalHttp && local && uri.scheme == 'http')) {
    throw const FormatException('Invalid API configuration');
  }
  return uri.replace(path: uri.path.endsWith('/') ? uri.path : '${uri.path}/');
}

abstract interface class AuthGateway {
  Uri get baseUri;
  Future<AuthSession> authenticate(
    String email,
    String password, {
    required bool register,
  });
  Future<AuthUser> me(String token);
  Future<void> logout(String token, {bool all = false});
  void close();
}

class HttpAuthGateway implements AuthGateway {
  HttpAuthGateway({
    required this.baseUri,
    http.Client Function()? clientFactory,
    this.timeout = const Duration(seconds: 15),
  }) : _clientFactory = clientFactory ?? http.Client.new;

  @override
  final Uri baseUri;
  final http.Client Function() _clientFactory;
  final Duration timeout;
  final Set<http.Client> _active = {};
  bool _closed = false;

  @override
  Future<AuthSession> authenticate(
    String email,
    String password, {
    required bool register,
  }) async {
    final value = await _request(
      'POST',
      'v1/auth/${register ? 'register' : 'login'}',
      body: {'email': email.trim().toLowerCase(), 'password': password},
    );
    try {
      return AuthSession.fromJson(value);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<AuthUser> me(String token) async {
    final value = await _request('GET', 'v1/me', token: token);
    try {
      return AuthUser.fromJson(value);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<void> logout(String token, {bool all = false}) async {
    await _request(
      'POST',
      'v1/auth/${all ? 'logout-all' : 'logout'}',
      token: token,
    );
  }

  static const _invalidResponse = AuthFailure(
    'Respons layanan akun tidak valid. Coba lagi nanti.',
  );

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    String? token,
    Map<String, String>? body,
  }) async {
    if (_closed) throw const AuthFailure('Layanan akun sudah ditutup.');
    final client = _clientFactory();
    _active.add(client);
    try {
      return await (() async {
        final request = http.Request(method, baseUri.resolve(path))
          ..followRedirects = false
          ..headers['Accept'] = 'application/json';
        if (token != null) request.headers['Authorization'] = 'Bearer $token';
        if (body != null) {
          request.headers['Content-Type'] = 'application/json; charset=utf-8';
          request.body = jsonEncode(body);
        }
        final response = await client.send(request);
        if (response.statusCode == 204 && path.startsWith('v1/auth/logout')) {
          return <String, dynamic>{};
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw _httpFailure(
            response.statusCode,
            response.headers['retry-after'],
            path,
          );
        }
        final type = response.headers['content-type']
            ?.split(';')
            .first
            .trim()
            .toLowerCase();
        if (type != 'application/json') throw _invalidResponse;
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          bytes.addAll(chunk);
          if (bytes.length > 65536) throw _invalidResponse;
        }
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map<String, dynamic>) throw _invalidResponse;
        return decoded;
      })().timeout(timeout);
    } on AuthFailure {
      rethrow;
    } on TimeoutException {
      throw const AuthFailure(
        'Koneksi terlalu lama. Periksa jaringan lalu coba lagi.',
      );
    } on FormatException {
      throw _invalidResponse;
    } catch (_) {
      throw const AuthFailure(
        'Tidak dapat terhubung ke layanan akun. Periksa koneksi lalu coba lagi.',
      );
    } finally {
      _active.remove(client);
      client.close();
    }
  }

  AuthFailure _httpFailure(int status, String? retry, String path) {
    return switch (status) {
      401 => AuthFailure(
        path == 'v1/auth/login'
            ? 'Email atau kata sandi tidak cocok.'
            : 'Sesi berakhir. Silakan masuk kembali.',
        status: status,
      ),
      409 => AuthFailure(
        'Email sudah terdaftar. Silakan masuk.',
        status: status,
      ),
      422 => AuthFailure(
        'Periksa email dan kata sandi yang diisi.',
        status: status,
      ),
      429 => AuthFailure(
        'Terlalu banyak percobaan. Coba lagi beberapa saat lagi.',
        status: status,
        retryAfter: Duration(
          seconds: (int.tryParse(retry ?? '') ?? 900).clamp(1, 900),
        ),
      ),
      _ => AuthFailure(
        'Layanan akun belum dapat digunakan. Coba lagi nanti.',
        status: status,
      ),
    };
  }

  @override
  void close() {
    _closed = true;
    for (final client in _active.toList()) {
      client.close();
    }
    _active.clear();
  }
}
