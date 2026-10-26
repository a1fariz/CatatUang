import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:catat_uang/backup/backup_codec.dart';
import 'package:catat_uang/bill.dart';
import 'package:catat_uang/settings.dart';
import 'package:catat_uang/transaction_repository.dart';
import 'auth_fakes.dart';
import 'sync_fakes.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late TransactionRepository source, target;
  late Directory folder;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('catat-external-backup-');
    source = TransactionRepository(
      factory: databaseFactoryFfiNoIsolate,
      databasePath: '${folder.path}/source.db',
    );
    target = TransactionRepository(
      factory: databaseFactoryFfiNoIsolate,
      databasePath: '${folder.path}/target.db',
    );
  });
  tearDown(() async {
    await source.close();
    await target.close();
    await folder.delete(recursive: true);
  });
  test(
    'encrypted file roundtrip protects content and detects wrong passphrase and tampering',
    () async {
      const password = 'frasa-backup-pengujian-panjang';
      final plain = jsonEncode({'secret_finance': 'catatan sangat pribadi'});
      final sealed = await sealBackup(plain, password);
      expect(utf8.decode(sealed), isNot(contains('catatan sangat pribadi')));
      expect(await openBackup(sealed, password), {
        'secret_finance': 'catatan sangat pribadi',
      });
      await expectLater(
        openBackup(sealed, 'frasa-yang-salah-untuk-backup'),
        throwsA(isA<BackupFailure>()),
      );
      final value = jsonDecode(utf8.decode(sealed)) as Map<String, dynamic>;
      final cipher = base64Decode(value['ciphertext'] as String);
      cipher[0] ^= 1;
      value['ciphertext'] = base64Encode(cipher);
      await expectLater(
        openBackup(utf8.encode(jsonEncode(value)), password),
        throwsA(isA<BackupFailure>()),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'snapshot preserves finance, settings and immutable uncertain operation on empty target',
    () async {
      await source.save(localTransaction());
      final bill = Bill(
        id: null,
        name: 'Internet',
        amount: 200000,
        dueAt: DateTime(2026, 10, 1),
        recurrence: BillRecurrence.monthly,
        reminderMinutes: null,
        status: BillStatus.active,
      );
      final billId = await source.saveBill(bill);
      await source.payBill(
        Bill(
          id: billId,
          name: bill.name,
          amount: bill.amount,
          dueAt: bill.dueAt,
          recurrence: bill.recurrence,
          reminderMinutes: null,
          status: BillStatus.active,
        ),
        DateTime(2026, 10, 1),
      );
      await source.saveSettings(const AppSettings(darkMode: true));
      await source.linkSync(
        server: Uri.parse('https://api.example.com/'),
        userId: testUser.id,
        email: testUser.email,
      );
      final binding = (await source.syncBinding())!;
      final operation = (await source.nextSyncOperation(binding.generation))!;
      final snapshot =
          jsonDecode(jsonEncode(await source.backupSnapshot()))
              as Map<String, dynamic>;
      expect(jsonEncode(snapshot), isNot(contains('access_token')));
      await target.restoreExternalBackup(snapshot);
      final restored = (await target.syncBinding())!;
      expect(restored.generation, isNot(binding.generation));
      expect(
        (await target.nextSyncOperation(restored.generation))!.toJson(),
        operation.toJson(),
      );
      expect((await target.listBills()).single.dueAt, DateTime(2026, 11, 1));
      expect((await target.getSettings()).darkMode, isTrue);
      expect(
        (await target.list(periodStart: DateTime(2026, 10))).single.amount,
        42000,
      );
      final tables = (await target.backupSnapshot())['tables'] as Map;
      expect(tables['bill_payments'], hasLength(1));
    },
  );
  test(
    'restore rejects non-empty targets and malformed data without partial writes',
    () async {
      await source.save(localTransaction());
      final snapshot =
          jsonDecode(jsonEncode(await source.backupSnapshot()))
              as Map<String, dynamic>;
      await target.save(localTransaction(note: 'Jangan ditimpa'));
      await expectLater(
        target.restoreExternalBackup(snapshot),
        throwsA(isA<BackupFailure>()),
      );
      expect(
        (await target.list(periodStart: DateTime(2026, 10))).single.note,
        'Jangan ditimpa',
      );
      await target.clearAllData();
      (snapshot['tables']['transactions'][0] as Map)['amount'] = -1;
      await expectLater(
        target.restoreExternalBackup(snapshot),
        throwsA(anything),
      );
      expect(await target.hasEntries(), isFalse);
      expect((await target.getSettings()).currencyCode, 'IDR');
    },
  );
}
