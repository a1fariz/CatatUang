import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Historical migration fixtures must remove every newer schema component,
// rather than merely lowering PRAGMA user_version on a current database.
Future<void> removeVersion10Schema(Database db) async {
  for (final table in [
    'bill_sync_binding',
    'bill_sync_maps',
    'bill_sync_outbox',
    'bill_sync_payment_ids',
    'bill_sync_recovery_backups',
  ]) {
    await db.execute('DROP TABLE $table');
  }
  await db.execute('ALTER TABLE bills DROP COLUMN timezone');
}
