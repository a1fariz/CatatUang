import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

const maxBackupBytes = 20 * 1024 * 1024;
const _iterations = 600000;
const _aad = 'catat-uang-backup/v1/aes256gcm/pbkdf2-sha256/600000';

class BackupFailure implements Exception {
  const BackupFailure(this.message);
  final String message;
}

Future<Uint8List> sealBackup(String snapshot, String password) =>
    compute(_seal, [snapshot, password]);
Future<Map<String, dynamic>> openBackup(Uint8List bytes, String password) =>
    compute(_open, (bytes, password));

void _password(String value) {
  if (value.runes.length < 15 || utf8.encode(value).length > 256) {
    throw const BackupFailure(
      'Frasa sandi harus 15 karakter atau lebih, maksimal 256 byte.',
    );
  }
}

Future<SecretKey> _key(String password, List<int> salt) => Pbkdf2(
  macAlgorithm: Hmac.sha256(),
  iterations: _iterations,
  bits: 256,
).deriveKeyFromPassword(password: password, nonce: salt);

Future<Uint8List> _seal(List<String> values) async {
  final snapshot = values[0], password = values[1];
  _password(password);
  final plain = utf8.encode(snapshot);
  if (plain.length > 12 * 1024 * 1024) {
    throw const BackupFailure('Data terlalu besar untuk format backup ini.');
  }
  final random = Random.secure();
  final salt = List.generate(16, (_) => random.nextInt(256));
  final algorithm = AesGcm.with256bits();
  final box = await algorithm.encrypt(
    plain,
    secretKey: await _key(password, salt),
    aad: utf8.encode(_aad),
  );
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'format': 'catat-uang-encrypted-backup',
        'version': 1,
        'iterations': _iterations,
        'salt': base64Encode(salt),
        'nonce': base64Encode(box.nonce),
        'ciphertext': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      }),
    ),
  );
}

Future<Map<String, dynamic>> _open((Uint8List, String) input) async {
  _password(input.$2);
  if (input.$1.length > maxBackupBytes) {
    throw const BackupFailure('File backup melebihi batas 20 MiB.');
  }
  try {
    final value = jsonDecode(utf8.decode(input.$1));
    if (value is! Map<String, dynamic> ||
        value['format'] != 'catat-uang-encrypted-backup' ||
        value['version'] != 1 ||
        value['iterations'] != _iterations) {
      throw const BackupFailure('Format atau versi backup tidak didukung.');
    }
    final salt = base64Decode(value['salt'] as String),
        nonce = base64Decode(value['nonce'] as String),
        cipher = base64Decode(value['ciphertext'] as String),
        mac = base64Decode(value['mac'] as String);
    if (salt.length != 16 ||
        nonce.length != 12 ||
        mac.length != 16 ||
        cipher.length > 12 * 1024 * 1024) {
      throw const BackupFailure('Struktur backup tidak valid.');
    }
    final plain = await AesGcm.with256bits().decrypt(
      SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
      secretKey: await _key(input.$2, salt),
      aad: utf8.encode(_aad),
    );
    final decoded = jsonDecode(utf8.decode(plain));
    if (decoded is! Map<String, dynamic>) {
      throw const BackupFailure('Isi backup tidak valid.');
    }
    return decoded;
  } on BackupFailure {
    rethrow;
  } catch (_) {
    throw const BackupFailure(
      'Frasa sandi salah atau file backup rusak. Data lokal tidak diubah.',
    );
  }
}
