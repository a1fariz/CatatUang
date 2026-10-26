part of '../transaction_repository.dart';

extension TransactionSyncRepository on TransactionRepository {
  Future<void> _createSyncTables(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE sync_binding (
      id INTEGER PRIMARY KEY CHECK(id=1), generation TEXT NOT NULL,
      server TEXT NOT NULL, user_id TEXT NOT NULL, email TEXT NOT NULL,
      currency TEXT NOT NULL, cursor INTEGER NOT NULL DEFAULT 0,
      last_success TEXT, dataset_id TEXT)''');
    await db.execute('''CREATE TABLE sync_transactions (
      remote_id TEXT PRIMARY KEY, local_id INTEGER UNIQUE,
      remote_version INTEGER NOT NULL DEFAULT 0,
      conflict_json TEXT, error TEXT)''');
    await db.execute(
      '''CREATE TABLE sync_outbox (
      seq INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT NOT NULL UNIQUE,
      remote_id TEXT NOT NULL, base_version INTEGER NOT NULL,
      deleted INTEGER NOT NULL, payload TEXT,
      status TEXT NOT NULL CHECK(status IN ('pending','inflight','invalid')))''',
    );
    await db.execute(
      'CREATE INDEX sync_outbox_record ON sync_outbox(remote_id,seq)',
    );
  }

  Future<SyncBinding?> _binding(DatabaseExecutor db) async {
    final rows = await db.query('sync_binding', where: 'id=1');
    return rows.isEmpty ? null : SyncBinding(rows.single);
  }

  Future<SyncBinding?> syncBinding() async => _binding(await _db);

  Future<void> pinSyncDataset(String generation, String dataset) async {
    if (!validSyncId(dataset)) {
      throw const FormatException('Invalid dataset ID');
    }
    await (await _db).transaction((txn) async {
      final binding = await _binding(txn);
      if (binding?.generation != generation) {
        throw const SyncFailure('Penautan catatan sudah berubah.');
      }
      if (binding!.datasetId != null) {
        if (binding.datasetId != dataset) {
          throw const SyncFailure(
            'Dataset server berubah. Sinkronisasi dihentikan; catatan dan antrean lokal tetap tersimpan. Perlu rekonsiliasi.',
            code: 'sync_reset_required',
          );
        }
        return;
      }
      final acknowledged = Sqflite.firstIntValue(
        await txn.rawQuery(
          'SELECT count(*) FROM sync_transactions WHERE remote_version>0',
        ),
      )!;
      final uncertain = Sqflite.firstIntValue(
        await txn.rawQuery(
          "SELECT count(*) FROM sync_outbox WHERE status='inflight'",
        ),
      )!;
      if (binding.cursor > 0 || acknowledged > 0 || uncertain > 0) {
        throw const SyncFailure(
          'Ledger dari versi lama belum memiliki identitas dataset. Perlu rekonsiliasi sebelum sinkronisasi; catatan dan antrean tetap tersimpan.',
          code: 'sync_reset_required',
        );
      }
      await txn.update('sync_binding', {'dataset_id': dataset}, where: 'id=1');
    });
  }

  Future<bool> _matches(DatabaseExecutor db, String generation) async =>
      (await _binding(db))?.generation == generation;

  Future<void> linkSync({
    required Uri server,
    required String userId,
    required String email,
  }) async {
    if (!validSyncId(userId)) throw ArgumentError('Invalid account');
    await (await _db).transaction((txn) async {
      final old = await _binding(txn);
      final billOwner = await _billBinding(txn);
      if (billOwner != null &&
          (billOwner.userId != userId ||
              billOwner.server != server.toString())) {
        throw const SyncFailure('Tagihan terhubung ke akun atau server lain.');
      }
      if (old != null) {
        if (old.server != server.toString() || old.userId != userId) {
          throw const SyncFailure(
            'Catatan ini terhubung ke akun atau server lain. Masuk dengan akun pemilik catatan.',
          );
        }
        return;
      }
      final settings = AppSettings.fromMap(
        (await txn.query('settings', where: 'id=1')).single,
      );
      await txn.insert('sync_binding', {
        'id': 1,
        'generation': syncId(),
        'server': server.toString(),
        'user_id': userId,
        'email': email,
        'currency': settings.currencyCode,
      });
      for (final row in await txn.query('transactions')) {
        await _queueLocal(txn, row['id'] as int);
      }
    });
  }

  Future<void> _queueLocal(
    DatabaseExecutor txn,
    int id, {
    bool deleted = false,
  }) async {
    final binding = await _binding(txn);
    if (binding == null) return;
    final mappings = await txn.query(
      'sync_transactions',
      where: 'local_id=?',
      whereArgs: [id],
    );
    final remote = mappings.isEmpty
        ? syncId()
        : mappings.single['remote_id'] as String;
    final version = mappings.isEmpty
        ? 0
        : mappings.single['remote_version'] as int;
    if (mappings.isEmpty) {
      await txn.insert('sync_transactions', {
        'remote_id': remote,
        'local_id': id,
        'remote_version': 0,
      });
    }
    // Only never-attempted operations may be replaced. An inflight request may
    // have committed despite a timeout and must retain its ID and exact body.
    await txn.delete(
      'sync_outbox',
      where: "remote_id=? AND status IN ('pending','invalid')",
      whereArgs: [remote],
    );
    final inflight = await txn.query(
      'sync_outbox',
      where: "remote_id=? AND status='inflight'",
      whereArgs: [remote],
    );
    if (deleted &&
        version == 0 &&
        inflight.isEmpty &&
        mappings.firstOrNull?['conflict_json'] == null) {
      await txn.delete(
        'sync_transactions',
        where: 'remote_id=?',
        whereArgs: [remote],
      );
      return;
    }
    Map<String, Object?>? payload;
    if (!deleted) {
      final row = (await txn.query(
        'transactions',
        where: 'id=?',
        whereArgs: [id],
      )).single;
      payload = transactionPayload(
        MoneyTransaction.fromMap(row),
        binding.currency,
      );
    }
    await txn.insert('sync_outbox', {
      'operation_id': syncId(),
      'remote_id': remote,
      'base_version': version,
      'deleted': deleted ? 1 : 0,
      'payload': payload == null ? null : jsonEncode(payload),
      'status': 'pending',
    });
    // A new edit can fix rejected input, but cannot silently resolve a conflict.
    await txn.update(
      'sync_transactions',
      {'error': null},
      where: 'remote_id=? AND conflict_json IS NULL',
      whereArgs: [remote],
    );
  }

  Future<int> syncPendingCount() async =>
      Sqflite.firstIntValue(
        await (await _db).rawQuery('SELECT count(*) FROM sync_outbox'),
      ) ??
      0;

  Future<List<SyncIssue>> syncIssues() async {
    final db = await _db;
    return db.transaction((txn) async {
      final issues = <SyncIssue>[];
      for (final row in await txn.query(
        'sync_transactions',
        where: 'conflict_json IS NOT NULL OR error IS NOT NULL',
      )) {
        final local = await txn.query(
          'transactions',
          where: 'id=?',
          whereArgs: [row['local_id']],
        );
        issues.add(
          SyncIssue(
            remoteId: row['remote_id'] as String,
            message:
                row['error'] as String? ??
                'Catatan di akun dan perangkat sama-sama berubah.',
            server: row['conflict_json'] == null
                ? null
                : SyncRecord.fromJson(
                    jsonDecode(row['conflict_json'] as String)
                        as Map<String, dynamic>,
                  ),
            local: local.isEmpty
                ? null
                : MoneyTransaction.fromMap(local.single),
          ),
        );
      }
      return issues;
    });
  }

  Future<SyncOperation?> nextSyncOperation(
    String generation, {
    bool inflightOnly = false,
  }) async => (await _db).transaction((txn) async {
    if (!await _matches(txn, generation)) return null;
    final rows = await txn.rawQuery(
      '''SELECT o.* FROM sync_outbox o
      JOIN sync_transactions m ON m.remote_id=o.remote_id
      WHERE m.conflict_json IS NULL AND m.error IS NULL
      AND o.status IN (${inflightOnly ? "'inflight'" : "'pending','inflight'"})
      AND NOT EXISTS (SELECT 1 FROM sync_outbox older WHERE older.remote_id=o.remote_id AND older.seq<o.seq)
      ORDER BY CASE o.status WHEN 'inflight' THEN 0 ELSE 1 END,o.seq LIMIT 1''',
    );
    if (rows.isEmpty) return null;
    await txn.update(
      'sync_outbox',
      {'status': 'inflight'},
      where: 'seq=?',
      whereArgs: [rows.single['seq']],
    );
    return SyncOperation(rows.single);
  });

  Future<void> acknowledgeSync(
    String generation,
    SyncOperation operation,
    SyncRecord record,
  ) async {
    if (record.id != operation.remoteId) {
      throw const FormatException('Mismatched receipt');
    }
    if (record.version != operation.baseVersion + 1 ||
        record.deleted != operation.deleted ||
        operation.payload != null &&
            operation.payload!.entries.any(
              (entry) => record.json[entry.key] != entry.value,
            )) {
      throw const FormatException('Receipt does not match operation');
    }
    await (await _db).transaction((txn) async {
      if (!await _matches(txn, generation)) return;
      final deleted = await txn.delete(
        'sync_outbox',
        where: 'operation_id=? AND remote_id=?',
        whereArgs: [operation.operationId, record.id],
      );
      if (deleted == 0) return;
      await txn.rawUpdate(
        'UPDATE sync_transactions SET remote_version=MAX(remote_version,?) WHERE remote_id=?',
        [record.version, record.id],
      );
      await txn.update(
        'sync_outbox',
        {'base_version': record.version},
        where: "remote_id=? AND status='pending'",
        whereArgs: [record.id],
      );
    });
  }

  Future<void> rejectSync(
    String generation,
    SyncOperation operation, {
    SyncRecord? server,
    String? error,
  }) async {
    if (server != null && server.id != operation.remoteId) {
      throw const FormatException('Mismatched conflict');
    }
    await (await _db).transaction((txn) async {
      if (!await _matches(txn, generation)) return;
      await txn.update(
        'sync_transactions',
        {
          'conflict_json': server == null ? null : jsonEncode(server.json),
          'error': error,
        },
        where: 'remote_id=?',
        whereArgs: [operation.remoteId],
      );
      if (server == null) {
        final newer = await txn.query(
          'sync_outbox',
          where: "remote_id=? AND status='pending'",
          whereArgs: [operation.remoteId],
          limit: 1,
        );
        if (newer.isNotEmpty) {
          await txn.delete(
            'sync_outbox',
            where: 'operation_id=?',
            whereArgs: [operation.operationId],
          );
          await txn.update(
            'sync_transactions',
            {'error': null},
            where: 'remote_id=?',
            whereArgs: [operation.remoteId],
          );
          return;
        }
        await txn.update(
          'sync_outbox',
          {'status': 'invalid'},
          where: 'operation_id=?',
          whereArgs: [operation.operationId],
        );
      }
    });
  }

  Future<void> _applyRemote(DatabaseExecutor txn, SyncRecord record) async {
    final maps = await txn.query(
      'sync_transactions',
      where: 'remote_id=?',
      whereArgs: [record.id],
    );
    final map = maps.firstOrNull;
    if (map != null && record.version <= (map['remote_version'] as int)) return;
    final queued = await txn.query(
      'sync_outbox',
      where: 'remote_id=?',
      whereArgs: [record.id],
      limit: 1,
    );
    if (queued.isNotEmpty) {
      final old = map?['conflict_json'];
      if (old == null ||
          SyncRecord.fromJson(
                jsonDecode(old as String) as Map<String, dynamic>,
              ).version <
              record.version) {
        await txn.update(
          'sync_transactions',
          {'conflict_json': jsonEncode(record.json), 'error': null},
          where: 'remote_id=?',
          whereArgs: [record.id],
        );
      }
      return;
    }
    var id = map?['local_id'] as int?;
    if (record.deleted) {
      if (id != null) {
        await txn.delete('transactions', where: 'id=?', whereArgs: [id]);
      }
    } else {
      id = await txn.insert(
        'transactions',
        record.local(id).toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await txn.insert('sync_transactions', {
      'remote_id': record.id,
      'local_id': id,
      'remote_version': record.version,
      'conflict_json': null,
      'error': null,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<bool> applySyncPage(
    String generation,
    int expectedCursor,
    SyncPage page,
  ) async => (await _db).transaction((txn) async {
    final binding = await _binding(txn);
    if (binding?.generation != generation ||
        binding!.cursor != expectedCursor) {
      return false;
    }
    if (page.cursor < expectedCursor) {
      throw const FormatException('Cursor moved backwards');
    }
    for (final record in page.items) {
      if (record.currency != binding.currency) {
        throw const SyncFailure(
          'Akun berisi mata uang berbeda. Sinkronisasi dihentikan agar nominal tidak salah ditafsirkan.',
        );
      }
      await _applyRemote(txn, record);
    }
    await txn.update('sync_binding', {'cursor': page.cursor}, where: 'id=1');
    return true;
  });

  Future<void> finishSync(String generation) async =>
      (await _db).transaction((txn) async {
        if (await _matches(txn, generation)) {
          await txn.update('sync_binding', {
            'last_success': DateTime.now().toUtc().toIso8601String(),
          }, where: 'id=1');
        }
      });

  Future<void> resolveSync(
    String generation,
    String remoteId, {
    required bool keepLocal,
  }) async => (await _db).transaction((txn) async {
    if (!await _matches(txn, generation)) {
      throw const SyncFailure('Penautan catatan sudah berubah.');
    }
    final map = (await txn.query(
      'sync_transactions',
      where: 'remote_id=?',
      whereArgs: [remoteId],
    )).single;
    if (map['conflict_json'] == null) {
      throw const SyncFailure('Snapshot konflik belum tersedia.');
    }
    final record = SyncRecord.fromJson(
      jsonDecode(map['conflict_json'] as String) as Map<String, dynamic>,
    );
    final binding = (await _binding(txn))!;
    if (record.currency != binding.currency) {
      throw const SyncFailure('Mata uang akun berbeda.');
    }
    await txn.delete(
      'sync_outbox',
      where: 'remote_id=?',
      whereArgs: [remoteId],
    );
    await txn.update(
      'sync_transactions',
      {
        'remote_version': keepLocal ? record.version : 0,
        'conflict_json': null,
        'error': null,
      },
      where: 'remote_id=?',
      whereArgs: [remoteId],
    );
    if (keepLocal) {
      final id = map['local_id'] as int?;
      final local = id == null
          ? <Map<String, Object?>>[]
          : await txn.query('transactions', where: 'id=?', whereArgs: [id]);
      if (id == null) throw const SyncFailure('Catatan lokal tidak tersedia.');
      await _queueLocal(txn, id, deleted: local.isEmpty);
    } else {
      await _applyRemote(txn, record);
    }
  });
}
