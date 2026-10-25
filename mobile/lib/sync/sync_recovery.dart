import 'dart:convert';

import '../transaction.dart';
import 'sync_models.dart';

class RecoveryItem {
  RecoveryItem({
    required this.id,
    required this.localId,
    required this.local,
    required this.server,
    this.keepLocal,
  });
  final String id;
  final int? localId;
  final MoneyTransaction? local;
  final SyncRecord? server;
  bool? keepLocal;
}

class RecoveryPlan {
  RecoveryPlan({
    required this.dataset,
    required this.cursor,
    required Map<String, dynamic> snapshot,
    required Map<String, SyncRecord> records,
  }) : fingerprint = jsonEncode(snapshot),
       binding = SyncBinding(
         Map<String, Object?>.from(snapshot['binding'] as Map),
       ) {
    final locals = {
      for (final row in snapshot['transactions'] as List)
        row['id'] as int: MoneyTransaction.fromMap(
          Map<String, Object?>.from(row as Map),
        ),
    };
    if (locals.length > 5000) {
      throw const SyncFailure(
        'Catatan lokal terlalu besar untuk peninjauan perangkat. Data tidak diubah.',
      );
    }
    final mapped = <int>{};
    final ids = <String>{};
    for (final row in snapshot['maps'] as List) {
      final id = row['remote_id'] as String;
      ids.add(id);
      final localId = row['local_id'] as int?;
      if (localId != null) mapped.add(localId);
      _add(id, localId, locals[localId], records[id], known: true);
    }
    for (final entry in locals.entries) {
      if (!mapped.contains(entry.key)) {
        _add(syncId(), entry.key, entry.value, null, known: true);
      }
    }
    for (final entry in records.entries) {
      if (!ids.contains(entry.key)) {
        _add(entry.key, null, null, entry.value, known: false);
      }
    }
    for (final row in snapshot['outbox'] as List) {
      if (!ids.contains(row['remote_id'])) {
        throw const SyncFailure(
          'Antrean tidak memiliki pemetaan catatan. Pemulihan dihentikan.',
        );
      }
    }
  }
  final String dataset, fingerprint;
  final int cursor;
  final SyncBinding binding;
  final List<RecoveryItem> items = [];
  int get unresolved => items.where((item) => item.keepLocal == null).length;
  void _add(
    String id,
    int? localId,
    MoneyTransaction? local,
    SyncRecord? remote, {
    required bool known,
  }) {
    if (remote != null && remote.currency != binding.currency) {
      throw const SyncFailure('Mata uang akun berbeda. Pemulihan dihentikan.');
    }
    final remoteAbsent = remote == null || remote.deleted;
    final same = local == null
        ? remoteAbsent
        : !remoteAbsent &&
              transactionPayload(
                local,
                binding.currency,
              ).entries.every((entry) => remote.json[entry.key] == entry.value);
    items.add(
      RecoveryItem(
        id: id,
        localId: localId,
        local: local,
        server: remote,
        keepLocal: same || !known ? false : null,
      ),
    );
  }
}

class RecoveryBackup {
  RecoveryBackup(Map<String, Object?> row)
    : id = row['id'] as String,
      createdAt = row['created_at'] as String;
  final String id, createdAt;
}
