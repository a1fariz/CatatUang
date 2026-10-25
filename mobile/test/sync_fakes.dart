import 'dart:async';
import 'dart:convert';

import 'package:catat_uang/sync/sync_api.dart';
import 'package:catat_uang/sync/sync_models.dart';
import 'package:catat_uang/transaction.dart';

SyncRecord operationReceipt(SyncOperation operation) => SyncRecord.fromJson({
  ...?operation.payload,
  'id': operation.remoteId,
  'version': operation.baseVersion + 1,
  'deleted': operation.deleted,
});

MoneyTransaction localTransaction({
  int? id,
  int amount = 42000,
  String note = 'Lokal',
}) => MoneyTransaction(
  id: id,
  type: TransactionType.expense,
  amount: amount,
  category: 'Makan',
  occurredAt: DateTime(2026, 10, 25),
  note: note,
);

SyncRecord remoteRecord({
  String? id,
  int version = 1,
  int amount = 42000,
  String note = 'Akun',
  bool deleted = false,
  String currency = 'IDR',
}) => SyncRecord.fromJson({
  'id': id ?? '22222222-2222-4222-8222-222222222222',
  ...transactionPayload(localTransaction(amount: amount, note: note), currency),
  'version': version,
  'deleted': deleted,
  'created_at': '2026-10-25T00:00:00Z',
  'updated_at': '2026-10-25T00:00:00Z',
});

// Models a server that can commit a POST and lose its response. Kept separate
// from SQLite so tests can reopen a device without losing server receipts.
class FakeSyncGateway implements TransactionSyncGateway {
  @override
  Uri get baseUri => Uri.parse('https://api.example.com/');
  final records = <String, SyncRecord>{};
  final changes = <SyncRecord>[];
  final receipts = <String, SyncRecord>{};
  final requests = <Map<String, Object?>>[];
  SyncFailure? pushFailure;
  Object? pullFailure;
  bool loseNextResponse = false;
  Completer<void>? pushGate;
  Completer<void>? pullGate;
  int pushes = 0, pulls = 0;
  String currentDataset = '33333333-3333-4333-8333-333333333333';
  @override
  Future<String> datasetId(String token) async => currentDataset;
  void _checkDataset(String? dataset) {
    if (dataset != currentDataset) {
      throw const SyncFailure(
        'Dataset changed',
        status: 409,
        code: 'sync_reset_required',
      );
    }
  }

  void change(SyncRecord record) {
    records[record.id] = record;
    changes.add(record);
  }

  @override
  Future<SyncRecord> push(
    String token,
    SyncOperation operation, {
    String? dataset,
  }) async {
    _checkDataset(dataset);
    pushes++;
    requests.add(
      jsonDecode(jsonEncode(operation.toJson())) as Map<String, Object?>,
    );
    await pushGate?.future;
    if (pushFailure != null) throw pushFailure!;
    final old = receipts[operation.operationId];
    if (old != null) return old;
    final current = records[operation.remoteId];
    if ((current?.version ?? 0) != operation.baseVersion) {
      throw const SyncFailure('conflict', status: 409);
    }
    final record = SyncRecord.fromJson({
      ...?operation.payload,
      ...?((operation.deleted) ? current?.json : null),
      'id': operation.remoteId,
      'version': operation.baseVersion + 1,
      'deleted': operation.deleted,
    });
    change(record);
    receipts[operation.operationId] = record;
    if (loseNextResponse) {
      loseNextResponse = false;
      throw const SyncFailure('response lost');
    }
    return record;
  }

  @override
  Future<SyncPage> pull(String token, int after, {String? dataset}) async {
    _checkDataset(dataset);
    pulls++;
    await pullGate?.future;
    if (pullFailure != null) throw pullFailure!;
    return SyncPage(
      items: changes.skip(after).toList(),
      cursor: changes.length,
      hasMore: false,
    );
  }

  @override
  Future<SyncRecord> snapshot(
    String token,
    String id, {
    String? dataset,
  }) async {
    _checkDataset(dataset);
    if (records[id] == null) throw const SyncFailure('not found', status: 404);
    return records[id]!;
  }

  @override
  void close() {}
}
