part of '../transaction_repository.dart';

extension BillSyncRepository on TransactionRepository {
  Future<void> _createBillSyncTables(DatabaseExecutor db) async {
    await db.execute(
      '''CREATE TABLE bill_sync_binding(id INTEGER PRIMARY KEY CHECK(id=1),generation TEXT NOT NULL,server TEXT NOT NULL,user_id TEXT NOT NULL,email TEXT NOT NULL,currency TEXT NOT NULL,cursor INTEGER NOT NULL DEFAULT 0,last_success TEXT,dataset_id TEXT,timezone TEXT NOT NULL)''',
    );
    await db.execute(
      '''CREATE TABLE bill_sync_maps(remote_id TEXT PRIMARY KEY,local_id INTEGER UNIQUE,remote_version INTEGER NOT NULL DEFAULT 0,conflict_json TEXT,error TEXT)''',
    );
    await db.execute(
      '''CREATE TABLE bill_sync_outbox(seq INTEGER PRIMARY KEY AUTOINCREMENT,operation_id TEXT NOT NULL UNIQUE,remote_id TEXT NOT NULL,base_version INTEGER NOT NULL,deleted INTEGER NOT NULL,payload TEXT,status TEXT NOT NULL CHECK(status IN ('pending','inflight','invalid')))''',
    );
    await db.execute(
      'CREATE INDEX bill_sync_outbox_record ON bill_sync_outbox(remote_id,seq)',
    );
    await db.execute(
      'CREATE TABLE bill_sync_payment_ids(local_id INTEGER PRIMARY KEY,remote_id TEXT NOT NULL UNIQUE)',
    );
    await db.execute(
      'CREATE TABLE bill_sync_recovery_backups(id TEXT PRIMARY KEY,created_at TEXT NOT NULL,snapshot TEXT NOT NULL)',
    );
  }

  Future<SyncBinding?> _billBinding(DatabaseExecutor db) async {
    final rows = await db.query('bill_sync_binding');
    return rows.isEmpty ? null : SyncBinding(rows.single);
  }

  Future<SyncBinding?> billSyncBinding() async => _billBinding(await _db);

  Future<Map<String, Object?>> _billRecoverySnapshot(
    DatabaseExecutor txn,
  ) async {
    final result = <String, Object?>{};
    for (final table in [
      'bill_sync_binding',
      'bill_sync_maps',
      'bill_sync_outbox',
      'bill_sync_payment_ids',
      'bills',
      'bill_payments',
    ]) {
      result[table] = await txn.query(table);
    }
    return result;
  }

  Future<Map<String, Object?>> billRecoverySnapshot() async =>
      (await _db).transaction(_billRecoverySnapshot);

  Future<void> reconcileBillDataset(
    String generation,
    String dataset,
    String fingerprint,
    List<BillSyncRecord> records,
  ) async {
    if (!validSyncId(dataset)) throw const FormatException('Invalid dataset');
    final ids = <String>{};
    for (final record in records) {
      if (!ids.add(record.id)) {
        throw const FormatException('Duplicate recovery record');
      }
    }
    await (await _db).transaction((txn) async {
      final binding = await _billBinding(txn);
      if (binding?.generation != generation) {
        throw const SyncFailure('Penautan tagihan berubah.');
      }
      final before = await _billRecoverySnapshot(txn);
      if (jsonEncode(before) != fingerprint) {
        throw const SyncFailure(
          'Tagihan berubah selama peninjauan. Ulangi peninjauan.',
        );
      }
      for (final record in records) {
        if (record.currency != binding!.currency) {
          throw const SyncFailure('Mata uang tagihan akun berbeda.');
        }
      }
      await txn.insert('bill_sync_recovery_backups', {
        'id': syncId(),
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'snapshot': jsonEncode(before),
      });
      // Reconcile every known UUID against the complete new account snapshot.
      // Matching IDs use the reviewed account version. Local-only bills keep
      // their history and receive fresh operation IDs in the new dataset.
      await txn.delete('bill_sync_outbox');
      final maps = await txn.query('bill_sync_maps');
      for (final record in records) {
        await _writeBillRemote(txn, record, force: true);
      }
      for (final map in maps.where((row) => !ids.contains(row['remote_id']))) {
        await txn.update(
          'bill_sync_maps',
          {'remote_version': 0, 'conflict_json': null, 'error': null},
          where: 'remote_id=?',
          whereArgs: [map['remote_id']],
        );
      }
      await txn.update('bill_sync_binding', {
        'dataset_id': dataset,
        'generation': syncId(),
        'cursor': 0,
        'last_success': null,
      }, where: 'id=1');
      for (final map in maps.where((row) => !ids.contains(row['remote_id']))) {
        final local = await txn.query(
          'bills',
          where: 'id=?',
          whereArgs: [map['local_id']],
        );
        if (local.isEmpty) {
          await txn.delete(
            'bill_sync_maps',
            where: 'remote_id=?',
            whereArgs: [map['remote_id']],
          );
        } else {
          await _queueBill(txn, map['local_id'] as int);
        }
      }
    });
  }

  Future<bool> _billMatches(DatabaseExecutor db, String generation) async =>
      (await _billBinding(db))?.generation == generation;
  Future<void> linkBillSync({
    required Uri server,
    required String userId,
    required String email,
    required String timezone,
  }) async {
    if (!validSyncId(userId)) throw ArgumentError('Invalid account');
    billZone(timezone);
    await (await _db).transaction((txn) async {
      final old = await _billBinding(txn), other = await _binding(txn);
      for (final b in [old, other]) {
        if (b != null &&
            (b.userId != userId || b.server != server.toString())) {
          throw const SyncFailure(
            'Masuk dengan akun dan server pemilik catatan.',
          );
        }
      }
      if (old != null) return;
      final settings = AppSettings.fromMap(
        (await txn.query('settings')).single,
      );
      await txn.insert('bill_sync_binding', {
        'id': 1,
        'generation': syncId(),
        'server': server.toString(),
        'user_id': userId,
        'email': email,
        'currency': settings.currencyCode,
        'timezone': timezone,
      });
      for (final row in await txn.query('bills')) {
        await _queueBill(txn, row['id'] as int);
      }
    });
  }

  Future<void> pinBillDataset(String generation, String dataset) async {
    if (!validSyncId(dataset)) throw const FormatException('Invalid dataset');
    await (await _db).transaction((txn) async {
      final binding = await _billBinding(txn);
      if (binding?.generation != generation) {
        throw const SyncFailure('Penautan tagihan berubah.');
      }
      if (binding!.datasetId != null && binding.datasetId != dataset) {
        throw const SyncFailure(
          'Dataset tagihan berubah. Ekspor backup sebelum rekonsiliasi; antrean tetap tersimpan.',
          code: 'sync_reset_required',
        );
      }
      await txn.update('bill_sync_binding', {
        'dataset_id': dataset,
      }, where: 'id=1');
    });
  }

  Future<void> _queueBill(
    DatabaseExecutor txn,
    int id, {
    bool deleted = false,
  }) async {
    final binding = await _billBinding(txn);
    if (binding == null) return;
    final maps = await txn.query(
      'bill_sync_maps',
      where: 'local_id=?',
      whereArgs: [id],
    );
    final map = maps.firstOrNull;
    final remote = map?['remote_id'] as String? ?? syncId();
    final version = map?['remote_version'] as int? ?? 0;
    if (map == null) {
      await txn.insert('bill_sync_maps', {
        'remote_id': remote,
        'local_id': id,
        'remote_version': 0,
      });
    }
    await txn.delete(
      'bill_sync_outbox',
      where: "remote_id=? AND status IN ('pending','invalid')",
      whereArgs: [remote],
    );
    final uncertain = await txn.query(
      'bill_sync_outbox',
      where: "remote_id=? AND status='inflight'",
      whereArgs: [remote],
    );
    if (deleted &&
        version == 0 &&
        uncertain.isEmpty &&
        map?['conflict_json'] == null) {
      await txn.delete(
        'bill_sync_maps',
        where: 'remote_id=?',
        whereArgs: [remote],
      );
      return;
    }
    Map<String, Object?>? payload;
    if (!deleted) {
      var row = (await txn.query(
        'bills',
        where: 'id=?',
        whereArgs: [id],
      )).single;
      if (row['timezone'] == null) {
        final zone = (await txn.query('bill_sync_binding')).single['timezone'];
        await txn.update(
          'bills',
          {'timezone': zone},
          where: 'id=?',
          whereArgs: [id],
        );
        row = {...row, 'timezone': zone};
      }
      final bill = Bill.fromMap(row);
      final payments = <Map<String, Object?>>[];
      for (final p in await txn.query(
        'bill_payments',
        where: 'bill_id=?',
        whereArgs: [id],
        orderBy: 'due_at,id',
      )) {
        final ids = await txn.query(
          'bill_sync_payment_ids',
          where: 'local_id=?',
          whereArgs: [p['id']],
        );
        final paymentId = ids.firstOrNull?['remote_id'] as String? ?? syncId();
        if (ids.isEmpty) {
          await txn.insert('bill_sync_payment_ids', {
            'local_id': p['id'],
            'remote_id': paymentId,
          });
        }
        payments.add({
          'id': paymentId,
          'bill_id': remote,
          'due_at': _billTimestamp(p['due_at'] as String, whole: true),
          'amount_minor': p['amount'],
          'currency_code': binding.currency,
          'paid_at': _billTimestamp(p['paid_at'] as String),
        });
      }
      payload = {
        'name': bill.name,
        'amount_minor': bill.amount,
        'currency_code': binding.currency,
        'due_at': _billTimestamp(row['due_at'] as String, whole: true),
        'timezone': bill.timezone,
        'recurrence': bill.recurrence.name,
        'recurrence_day': bill.recurrenceDay,
        'reminder_minutes': bill.reminderMinutes,
        'status': bill.status.name,
        'paid_at': bill.paidAt?.toUtc().toIso8601String(),
        'payments': payments,
      };
    }
    await txn.insert('bill_sync_outbox', {
      'operation_id': syncId(),
      'remote_id': remote,
      'base_version': version,
      'deleted': deleted ? 1 : 0,
      'payload': payload == null ? null : jsonEncode(payload),
      'status': 'pending',
    });
    await txn.update(
      'bill_sync_maps',
      {'error': null},
      where: 'remote_id=? AND conflict_json IS NULL',
      whereArgs: [remote],
    );
  }

  String _billTimestamp(String value, {bool whole = false}) {
    var date = DateTime.parse(value).toUtc();
    if (whole) {
      date = DateTime.fromMillisecondsSinceEpoch(
        date.millisecondsSinceEpoch ~/ 1000 * 1000,
        isUtc: true,
      );
    }
    return date.toIso8601String();
  }

  Future<int> billSyncPendingCount() async =>
      Sqflite.firstIntValue(
        await (await _db).rawQuery('SELECT count(*) FROM bill_sync_outbox'),
      ) ??
      0;
  Future<List<Map<String, Object?>>> billSyncIssues() async =>
      (await _db).query(
        'bill_sync_maps',
        where: 'conflict_json IS NOT NULL OR error IS NOT NULL',
      );
  Future<SyncOperation?> nextBillOperation(
    String generation, {
    bool inflightOnly = false,
  }) async => (await _db).transaction((txn) async {
    if (!await _billMatches(txn, generation)) return null;
    final rows = await txn.rawQuery(
      '''SELECT o.* FROM bill_sync_outbox o JOIN bill_sync_maps m ON m.remote_id=o.remote_id WHERE m.conflict_json IS NULL AND m.error IS NULL AND o.status IN (${inflightOnly ? "'inflight'" : "'pending','inflight'"}) AND NOT EXISTS(SELECT 1 FROM bill_sync_outbox older WHERE older.remote_id=o.remote_id AND older.seq<o.seq) ORDER BY CASE o.status WHEN 'inflight' THEN 0 ELSE 1 END,o.seq LIMIT 1''',
    );
    if (rows.isEmpty) return null;
    await txn.update(
      'bill_sync_outbox',
      {'status': 'inflight'},
      where: 'seq=?',
      whereArgs: [rows.single['seq']],
    );
    return SyncOperation(rows.single);
  });
  Future<void> acknowledgeBill(
    String generation,
    SyncOperation operation,
    BillSyncRecord record,
  ) async {
    if (record.id != operation.remoteId ||
        record.version <= operation.baseVersion ||
        record.version > operation.baseVersion + 2 ||
        record.deleted != operation.deleted) {
      throw const FormatException('Mismatched bill receipt');
    }
    final payload = operation.payload;
    if (payload != null) {
      bool equalValue(String key, Object? a, Object? b) {
        if (const ['due_at', 'paid_at'].contains(key) &&
            a != null &&
            b != null) {
          return DateTime.parse(
            a as String,
          ).isAtSameMomentAs(DateTime.parse(b as String));
        }
        return a == b;
      }

      for (final entry in payload.entries.where(
        (entry) => entry.key != 'payments',
      )) {
        if (!equalValue(entry.key, entry.value, record.json[entry.key])) {
          throw const FormatException('Bill receipt differs from operation');
        }
      }
      final expected = payload['payments'] as List;
      if (expected.length != record.payments.length) {
        throw const FormatException('Payment receipt differs');
      }
      for (final payment in expected) {
        final actual = record.payments
            .where((p) => p['id'] == payment['id'])
            .firstOrNull;
        if (actual == null ||
            (payment as Map).entries.any(
              (entry) => !equalValue(
                entry.key as String,
                entry.value,
                actual[entry.key],
              ),
            )) {
          throw const FormatException('Payment receipt differs');
        }
      }
    }
    await (await _db).transaction((txn) async {
      if (!await _billMatches(txn, generation)) return;
      final removed = await txn.delete(
        'bill_sync_outbox',
        where: 'operation_id=? AND remote_id=?',
        whereArgs: [operation.operationId, record.id],
      );
      if (removed == 0) return;
      await txn.update(
        'bill_sync_maps',
        {'remote_version': record.version},
        where: 'remote_id=?',
        whereArgs: [record.id],
      );
      await txn.update(
        'bill_sync_outbox',
        {'base_version': record.version},
        where: "remote_id=? AND status='pending'",
        whereArgs: [record.id],
      );
    });
  }

  Future<void> rejectBill(
    String generation,
    SyncOperation operation, {
    BillSyncRecord? server,
    String? error,
  }) async {
    if (server != null && server.id != operation.remoteId) {
      throw const FormatException('Mismatched bill conflict');
    }
    await (await _db).transaction((txn) async {
      if (!await _billMatches(txn, generation)) return;
      await txn.update(
        'bill_sync_maps',
        {
          'conflict_json': server == null ? null : jsonEncode(server.json),
          'error': error,
        },
        where: 'remote_id=?',
        whereArgs: [operation.remoteId],
      );
      if (server == null) {
        await txn.update(
          'bill_sync_outbox',
          {'status': 'invalid'},
          where: 'operation_id=?',
          whereArgs: [operation.operationId],
        );
      }
    });
  }

  Future<void> _writeBillRemote(
    DatabaseExecutor txn,
    BillSyncRecord record, {
    bool force = false,
  }) async {
    final map = (await txn.query(
      'bill_sync_maps',
      where: 'remote_id=?',
      whereArgs: [record.id],
    )).firstOrNull;
    if (!force && record.version <= (map?['remote_version'] as int? ?? 0)) {
      return;
    }
    final queued = await txn.query(
      'bill_sync_outbox',
      where: 'remote_id=?',
      whereArgs: [record.id],
      limit: 1,
    );
    if (!force && queued.isNotEmpty) {
      final old = map?['conflict_json'];
      if (old == null ||
          BillSyncRecord.fromJson(
                jsonDecode(old as String) as Map<String, dynamic>,
              ).version <
              record.version) {
        await txn.update(
          'bill_sync_maps',
          {'conflict_json': jsonEncode(record.json), 'error': null},
          where: 'remote_id=?',
          whereArgs: [record.id],
        );
      }
      return;
    }
    var id = map?['local_id'] as int?;
    if (id != null) {
      final old = await txn.query(
        'bill_payments',
        where: 'bill_id=?',
        whereArgs: [id],
      );
      for (final p in old) {
        await txn.delete(
          'bill_sync_payment_ids',
          where: 'local_id=?',
          whereArgs: [p['id']],
        );
      }
      await txn.delete('bill_payments', where: 'bill_id=?', whereArgs: [id]);
    }
    if (record.deleted) {
      if (id != null) await txn.delete('bills', where: 'id=?', whereArgs: [id]);
    } else {
      id = await txn.insert(
        'bills',
        record.local(id).toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (final p in record.payments) {
        final paymentId = await txn.insert('bill_payments', {
          'bill_id': id,
          'due_at': DateTime.parse(
            p['due_at'] as String,
          ).toLocal().toIso8601String(),
          'amount': p['amount_minor'],
          'paid_at': DateTime.parse(
            p['paid_at'] as String,
          ).toLocal().toIso8601String(),
        });
        await txn.insert('bill_sync_payment_ids', {
          'local_id': paymentId,
          'remote_id': p['id'],
        });
      }
    }
    await txn.insert('bill_sync_maps', {
      'remote_id': record.id,
      'local_id': id,
      'remote_version': record.version,
      'conflict_json': null,
      'error': null,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> applyBillPage(
    String generation,
    int expectedCursor,
    List<BillSyncRecord> records,
    int cursor,
  ) async {
    await (await _db).transaction((txn) async {
      final binding = await _billBinding(txn);
      if (binding?.generation != generation ||
          binding!.cursor != expectedCursor) {
        throw const SyncFailure('Penautan tagihan berubah.');
      }
      if (cursor < expectedCursor) {
        throw const FormatException('Cursor moved backwards');
      }
      for (final record in records) {
        if (record.currency != binding.currency) {
          throw const SyncFailure('Mata uang tagihan akun berbeda.');
        }
        await _writeBillRemote(txn, record);
      }
      await txn.update('bill_sync_binding', {'cursor': cursor}, where: 'id=1');
    });
  }

  Future<void> resolveBill(
    String generation,
    String remoteId, {
    required bool useServer,
  }) async {
    await (await _db).transaction((txn) async {
      if (!await _billMatches(txn, generation)) {
        throw const SyncFailure('Penautan tagihan berubah.');
      }
      final map = (await txn.query(
        'bill_sync_maps',
        where: 'remote_id=?',
        whereArgs: [remoteId],
      )).single;
      if (map['conflict_json'] == null) {
        throw const SyncFailure('Snapshot konflik belum tersedia.');
      }
      final record = BillSyncRecord.fromJson(
        jsonDecode(map['conflict_json'] as String) as Map<String, dynamic>,
      );
      if (record.currency != (await _billBinding(txn))!.currency) {
        throw const SyncFailure('Mata uang akun berbeda.');
      }
      if (!useServer) {
        throw const SyncFailure(
          'Ekspor backup dahulu, lalu pilih versi akun. Riwayat pembayaran tidak boleh ditimpa otomatis.',
        );
      }
      await txn.delete(
        'bill_sync_outbox',
        where: 'remote_id=?',
        whereArgs: [remoteId],
      );
      await _writeBillRemote(txn, record, force: true);
    });
  }
}
