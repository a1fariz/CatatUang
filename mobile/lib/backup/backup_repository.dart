part of '../transaction_repository.dart';

const _backupTables = [
  'settings',
  'transactions',
  'bills',
  'bill_payments',
  'sync_binding',
  'sync_transactions',
  'sync_outbox',
  'sync_recovery_backups',
];

extension ExternalBackupRepository on TransactionRepository {
  Future<Map<String, dynamic>> backupSnapshot() async =>
      (await _db).transaction((txn) async {
        final tables = <String, Object?>{};
        for (final table in _backupTables) {
          tables[table] = await txn.query(table);
        }
        return {
          'format': 'catat-uang-local-data',
          'version': 1,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'tables': tables,
        };
      });

  Future<void> restoreExternalBackup(Map<String, dynamic> backup) async {
    if (backup['format'] != 'catat-uang-local-data' ||
        backup['version'] != 1 ||
        backup['tables'] is! Map) {
      throw const BackupFailure('Isi atau versi backup tidak didukung.');
    }
    final tables = Map<String, dynamic>.from(backup['tables'] as Map);
    if (tables.length != _backupTables.length ||
        tables.keys.any((key) => !_backupTables.contains(key))) {
      throw const BackupFailure('Daftar tabel backup tidak valid.');
    }
    await (await _db).transaction((txn) async {
      for (final table in _backupTables.where((table) => table != 'settings')) {
        if ((Sqflite.firstIntValue(
                  await txn.rawQuery('SELECT count(*) FROM $table'),
                ) ??
                0) !=
            0) {
          throw const BackupFailure(
            'Pemulihan file hanya tersedia pada perangkat dengan data lokal kosong. Ekspor data saat ini sebelum mengosongkannya.',
          );
        }
      }
      var total = 0;
      for (final table in _backupTables) {
        final rows = tables[table];
        if (rows is! List) {
          throw const BackupFailure('Baris tabel backup tidak valid.');
        }
        total += rows.length;
        if (total > 100000) {
          throw const BackupFailure('Backup memiliki terlalu banyak baris.');
        }
        final columns = (await txn.rawQuery(
          'PRAGMA table_info($table)',
        )).map((row) => row['name']).toSet();
        for (final raw in rows) {
          if (raw is! Map ||
              raw.keys.any((key) => !columns.contains(key)) ||
              raw.values.any(
                (value) => value != null && value is! String && value is! int,
              )) {
            throw const BackupFailure('Kolom atau nilai backup tidak valid.');
          }
        }
      }
      for (final row in tables['sync_transactions'] as List) {
        if (!validSyncId(row['remote_id']) ||
            row['remote_version'] is! int ||
            (row['remote_version'] as int) < 0) {
          throw const BackupFailure('Pemetaan sinkronisasi tidak valid.');
        }
      }
      for (final row in tables['sync_outbox'] as List) {
        if (!validSyncId(row['operation_id']) ||
            !validSyncId(row['remote_id']) ||
            row['base_version'] is! int ||
            (row['base_version'] as int) < 0) {
          throw const BackupFailure('Identitas antrean tidak valid.');
        }
        if (row['payload'] != null &&
            jsonDecode(row['payload'] as String) is! Map<String, dynamic>) {
          throw const BackupFailure('Payload antrean tidak valid.');
        }
      }
      for (final row in tables['sync_binding'] as List) {
        final binding = SyncBinding(Map<String, Object?>.from(row as Map));
        final uri = Uri.tryParse(binding.server);
        if (!validSyncId(binding.userId) ||
            binding.datasetId != null && !validSyncId(binding.datasetId) ||
            binding.cursor < 0 ||
            uri == null ||
            !uri.hasAuthority ||
            !const ['http', 'https'].contains(uri.scheme) ||
            uri.userInfo.isNotEmpty ||
            uri.hasQuery ||
            uri.hasFragment ||
            binding.lastSuccess != null &&
                DateTime.tryParse(binding.lastSuccess!) == null) {
          throw const BackupFailure('Penautan akun backup tidak valid.');
        }
      }
      for (final row in tables['sync_recovery_backups'] as List) {
        final nested = jsonDecode(row['snapshot'] as String);
        if (nested is! Map<String, dynamic> ||
            nested['schema'] != 1 ||
            nested['binding'] is! Map ||
            nested['binding']['user_id'] != row['user_id'] ||
            nested['binding']['server'] != row['server']) {
          throw const BackupFailure('Cadangan pemulihan tidak valid.');
        }
        for (final entry in {
          'transactions': 'transactions',
          'maps': 'sync_transactions',
          'outbox': 'sync_outbox',
        }.entries) {
          final values = nested[entry.key];
          final columns = (await txn.rawQuery(
            'PRAGMA table_info(${entry.value})',
          )).map((column) => column['name']).toSet();
          if (values is! List ||
              values.any(
                (item) =>
                    item is! Map ||
                    item.keys.any((key) => !columns.contains(key)),
              )) {
            throw const BackupFailure('Kolom cadangan pemulihan tidak valid.');
          }
        }
        final bindingColumns = (await txn.rawQuery(
          'PRAGMA table_info(sync_binding)',
        )).map((column) => column['name']).toSet();
        if ((nested['binding'] as Map).keys.any(
          (key) => !bindingColumns.contains(key),
        )) {
          throw const BackupFailure('Kolom penautan cadangan tidak valid.');
        }
      }
      if ((tables['settings'] as List).length != 1 ||
          (tables['sync_binding'] as List).length > 1) {
        throw const BackupFailure(
          'Pengaturan atau penautan backup tidak valid.',
        );
      }
      for (final raw in tables['transactions'] as List) {
        MoneyTransaction.fromMap(Map<String, Object?>.from(raw as Map));
      }
      for (final raw in tables['bills'] as List) {
        Bill.fromMap(Map<String, Object?>.from(raw as Map));
      }
      final settings = AppSettings.fromMap(
        Map<String, Object?>.from((tables['settings'] as List).single as Map),
      );
      if (!const ['IDR', 'USD', 'EUR', 'SGD'].contains(settings.currencyCode)) {
        throw const BackupFailure('Mata uang backup tidak didukung.');
      }
      final billIds = (tables['bills'] as List).map((row) => row['id']).toSet();
      if ((tables['bill_payments'] as List).any(
        (row) => !billIds.contains(row['bill_id']),
      )) {
        throw const BackupFailure('Riwayat pembayaran kehilangan tagihannya.');
      }
      final remoteIds = (tables['sync_transactions'] as List)
          .map((row) => row['remote_id'])
          .toSet();
      if ((tables['sync_outbox'] as List).any(
        (row) => !remoteIds.contains(row['remote_id']),
      )) {
        throw const BackupFailure(
          'Antrean backup kehilangan pemetaan transaksi.',
        );
      }
      if ((tables['sync_binding'] as List).isEmpty && remoteIds.isNotEmpty) {
        throw const BackupFailure('Pemetaan backup tidak memiliki pemilik.');
      }
      await txn.delete('settings');
      for (final table in _backupTables) {
        for (final raw in tables[table] as List) {
          final row = Map<String, Object?>.from(raw as Map);
          if (table == 'sync_binding') {
            row['generation'] = syncId();
          }
          await txn.insert(table, row);
        }
      }
    });
  }
}
