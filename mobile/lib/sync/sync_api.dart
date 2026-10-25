import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/auth_models.dart';
import 'sync_models.dart';

abstract interface class TransactionSyncGateway {
  Uri get baseUri;
  Future<String> datasetId(String token);
  Future<SyncPage> pull(String token, int after, {String? dataset});
  Future<SyncRecord> push(
    String token,
    SyncOperation operation, {
    String? dataset,
  });
  Future<SyncRecord> snapshot(String token, String id, {String? dataset});
  void close();
}

class HttpTransactionSyncGateway implements TransactionSyncGateway {
  HttpTransactionSyncGateway({
    required this.baseUri,
    http.Client Function()? clientFactory,
    this.timeout = const Duration(seconds: 15),
  }) : _factory = clientFactory ?? http.Client.new;
  @override
  final Uri baseUri;
  final http.Client Function() _factory;
  final Duration timeout;
  final Set<http.Client> _active = {};
  bool _closed = false;

  @override
  Future<String> datasetId(String token) async {
    final value = (await _request('GET', 'v1/sync/state', token))['dataset_id'];
    if (!validSyncId(value)) {
      throw const SyncFailure('Identitas dataset server tidak valid.');
    }
    return value as String;
  }

  @override
  Future<SyncPage> pull(String token, int after, {String? dataset}) async =>
      SyncPage.fromJson(
        await _request(
          'GET',
          'v1/sync/transactions?after=$after&limit=50',
          token,
          dataset: dataset,
        ),
        after,
      );
  @override
  Future<SyncRecord> push(
    String token,
    SyncOperation operation, {
    String? dataset,
  }) async => SyncRecord.fromJson(
    await _request(
      'POST',
      'v1/sync/transactions',
      token,
      body: operation.toJson(),
      dataset: dataset,
    ),
  );
  @override
  Future<SyncRecord> snapshot(
    String token,
    String id, {
    String? dataset,
  }) async {
    if (!validSyncId(id)) throw const FormatException('Invalid record ID');
    return SyncRecord.fromJson(
      await _request(
        'GET',
        'v1/sync/transactions/$id',
        token,
        dataset: dataset,
      ),
    );
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path,
    String token, {
    Map<String, Object?>? body,
    String? dataset,
  }) async {
    if (_closed) throw const SyncFailure('Sinkronisasi sudah ditutup.');
    final client = _factory();
    _active.add(client);
    try {
      return await (() async {
        final request = http.Request(method, baseUri.resolve(path))
          ..followRedirects = false
          ..headers['Accept'] = 'application/json'
          ..headers['Authorization'] = 'Bearer $token';
        if (dataset != null) request.headers['X-Sync-Dataset'] = dataset;
        if (body != null) {
          request.headers['Content-Type'] = 'application/json; charset=utf-8';
          request.body = jsonEncode(body);
        }
        final response = await client.send(request);
        if (response.statusCode == 401) {
          throw const AuthFailure(
            'Sesi berakhir. Silakan masuk kembali.',
            status: 401,
          );
        }
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > 1048576) {
            throw const FormatException('Sync response too large');
          }
          bytes.addAll(chunk);
        }
        Map<String, dynamic>? decoded;
        if (response.headers['content-type']
                ?.split(';')
                .first
                .trim()
                .toLowerCase() ==
            'application/json') {
          final value = jsonDecode(utf8.decode(bytes));
          if (value is Map<String, dynamic>) decoded = value;
        }
        if (response.statusCode != 200) {
          final error = decoded?['error'];
          final reset = error is Map && error['code'] == 'sync_reset_required';
          throw SyncFailure(
            reset
                ? 'Data server dipulihkan atau posisi sinkronisasi berubah. Perlu rekonsiliasi sebelum melanjutkan.'
                : switch (response.statusCode) {
                    409 => 'Catatan di akun telah berubah.',
                    422 =>
                      'Catatan ditolak server. Periksa tanggal, nominal, kategori, dan panjang catatan.',
                    404 => 'Catatan akun tidak ditemukan.',
                    428 =>
                      'Versi aplikasi belum mendukung identitas dataset server. Perbarui aplikasi; catatan lokal tetap tersimpan.',
                    _ =>
                      'Layanan sinkronisasi belum dapat digunakan. Coba lagi.',
                  },
            status: response.statusCode,
            code: reset ? 'sync_reset_required' : null,
          );
        }
        if (decoded == null) throw const FormatException('Invalid sync JSON');
        return decoded;
      })().timeout(timeout);
    } on AuthFailure {
      rethrow;
    } on SyncFailure {
      rethrow;
    } on FormatException {
      throw const SyncFailure(
        'Respons sinkronisasi tidak valid. Data lokal tetap tersimpan.',
      );
    } on TimeoutException {
      throw const SyncFailure(
        'Koneksi terlalu lama. Coba sinkronkan lagi; perubahan lokal tetap tersimpan.',
      );
    } catch (_) {
      throw const SyncFailure(
        'Tidak dapat terhubung. Periksa jaringan lalu coba sinkronkan lagi.',
      );
    } finally {
      _active.remove(client);
      client.close();
    }
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
