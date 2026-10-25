part of '../transaction_repository.dart';

extension TransactionRecoveryRepository on TransactionRepository {
  Future<void> _createRecoveryTable(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE sync_recovery_backups (
      id TEXT PRIMARY KEY,created_at TEXT NOT NULL,user_id TEXT NOT NULL,
      server TEXT NOT NULL,snapshot TEXT NOT NULL)''');
  }

  Future<Map<String, dynamic>> _recoverySnapshot(DatabaseExecutor db) async {
    final binding = await db.query('sync_binding', where: 'id=1');
    if (binding.isEmpty) throw const SyncFailure('Catatan belum ditautkan.');
    return {
      'schema': 1,
      'binding': binding.single,
      'transactions': await db.query('transactions', orderBy: 'id'),
      'maps': await db.query('sync_transactions', orderBy: 'remote_id'),
      'outbox': await db.query('sync_outbox', orderBy: 'seq'),
    };
  }

  Future<Map<String, dynamic>> recoverySnapshot() async =>
      (await _db).transaction(_recoverySnapshot);

  Future<void> _saveRecoveryBackup(
    DatabaseExecutor txn,
    Map<String, dynamic> snapshot,
  ) async {
    final binding = snapshot['binding'] as Map;
    await txn.insert('sync_recovery_backups', {
      'id': syncId(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'user_id': binding['user_id'],
      'server': binding['server'],
      'snapshot': jsonEncode(snapshot),
    });
  }

  Future<List<RecoveryBackup>> recoveryBackups() async {
    return (await _db).transaction((txn) async {
      final binding = await _binding(txn);
      if (binding == null) return [];
      return (await txn.query(
        'sync_recovery_backups',
        columns: ['id', 'created_at'],
        where: 'user_id=? AND server=?',
        whereArgs: [binding.userId, binding.server],
        orderBy: 'created_at DESC,id',
      )).map(RecoveryBackup.new).toList();
    });
  }

  Future<void> applyRecovery(
    RecoveryPlan plan,
  ) async => (await _db).transaction((txn) async {
    final snapshot = await _recoverySnapshot(txn);
    if (jsonEncode(snapshot) != plan.fingerprint) {
      throw const SyncFailure(
        'Catatan berubah sejak peninjauan. Tinjau ulang sebelum menerapkan pemulihan.',
      );
    }
    if (plan.unresolved != 0 || !validSyncId(plan.dataset)) {
      throw const SyncFailure(
        'Tentukan pilihan untuk seluruh perbedaan catatan.',
      );
    }
    await _saveRecoveryBackup(txn, snapshot);
    await txn.delete('sync_outbox');
    await txn.delete('sync_transactions');
    await txn.delete('transactions');
    for (final item in plan.items) {
      final remote = item.server;
      final version = remote?.version ?? 0;
      final selected = item.keepLocal!
          ? item.local
          : remote == null || remote.deleted
          ? null
          : remote.local(item.localId);
      int? localId = item.localId;
      if (selected != null) {
        localId = await txn.insert('transactions', selected.toMap());
      }
      await txn.insert('sync_transactions', {
        'remote_id': item.id,
        'local_id': localId,
        'remote_version': version,
      });
      if (item.keepLocal! &&
          (item.local != null || remote != null && !remote.deleted)) {
        await txn.insert('sync_outbox', {
          'operation_id': syncId(),
          'remote_id': item.id,
          'base_version': version,
          'deleted': item.local == null ? 1 : 0,
          'payload': item.local == null
              ? null
              : jsonEncode(
                  transactionPayload(item.local!, plan.binding.currency),
                ),
          'status': 'pending',
        });
      }
    }
    await txn.update('sync_binding', {
      'generation': syncId(),
      'dataset_id': plan.dataset,
      'cursor': plan.cursor,
      'last_success': null,
    }, where: 'id=1');
  });

  Future<void> restoreRecoveryBackup(
    String generation,
    String backupId,
  ) async => (await _db).transaction((txn) async {
    final binding = await _binding(txn);
    if (binding?.generation != generation) {
      throw const SyncFailure('Penautan catatan sudah berubah.');
    }
    final rows = await txn.query(
      'sync_recovery_backups',
      where: 'id=? AND user_id=? AND server=?',
      whereArgs: [backupId, binding!.userId, binding.server],
    );
    if (rows.isEmpty) {
      throw const SyncFailure('Cadangan tidak ditemukan untuk catatan ini.');
    }
    final saved =
        jsonDecode(rows.single['snapshot'] as String) as Map<String, dynamic>;
    if (saved['schema'] != 1) {
      throw const SyncFailure('Format cadangan tidak didukung.');
    }
    await _saveRecoveryBackup(txn, await _recoverySnapshot(txn));
    await txn.delete('sync_outbox');
    await txn.delete('sync_transactions');
    await txn.delete('transactions');
    for (final pair in [
      ('transactions', 'transactions'),
      ('maps', 'sync_transactions'),
      ('outbox', 'sync_outbox'),
    ]) {
      for (final row in saved[pair.$1] as List) {
        await txn.insert(pair.$2, Map<String, Object?>.from(row as Map));
      }
    }
    final restored = Map<String, Object?>.from(saved['binding'] as Map)
      ..['generation'] = syncId()
      ..['last_success'] = null;
    await txn.update('sync_binding', restored, where: 'id=1');
  });
}
