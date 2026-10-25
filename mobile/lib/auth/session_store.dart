import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth_models.dart';

abstract interface class SessionStore {
  Future<AuthSession?> read();
  Future<void> write(AuthSession session);
  Future<void> clear();
}

class SecureSessionStore implements SessionStore {
  SecureSessionStore({required Uri server, FlutterSecureStorage? storage})
    : _server = server.toString(),
      _key =
          'catatuang.session.v1.${base64Url.encode(utf8.encode(server.toString()))}',
      _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.unlocked_this_device,
            ),
          );

  final FlutterSecureStorage _storage;
  final String _server;
  final String _key;

  @override
  Future<AuthSession?> read() async {
    final value = await _storage.read(key: _key);
    if (value == null) return null;
    final parsed = jsonDecode(value);
    if (parsed is! Map<String, dynamic> ||
        parsed['server'] != _server ||
        parsed['session'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid stored session');
    }
    return AuthSession.fromJson(parsed['session'] as Map<String, dynamic>);
  }

  @override
  Future<void> write(AuthSession session) async {
    final value = jsonEncode({'server': _server, 'session': session.toJson()});
    await _storage.write(key: _key, value: value);
    // Detect platform misconfiguration instead of claiming persistence succeeded.
    if (await _storage.read(key: _key) != value) {
      throw StateError('Secure session verification failed');
    }
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _key);
    if (await _storage.read(key: _key) != null) {
      throw StateError('Secure session deletion verification failed');
    }
  }
}
