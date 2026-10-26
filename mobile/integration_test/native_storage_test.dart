import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:catat_uang/backup/backup_codec.dart';
import 'package:catat_uang/bill.dart';
import 'package:catat_uang/reminder_service.dart';
import 'package:catat_uang/settings.dart';
import 'package:catat_uang/transaction.dart';
import 'package:catat_uang/transaction_repository.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native SQLite backup transfer, reopen and notification schedule persistence',
    (tester) async {
      final root = await Directory(
        await getDatabasesPath(),
      ).create(recursive: true);
      final folder = await root.createTemp('catat-native-');
      final a = TransactionRepository(
        databasePath: path.join(folder.path, 'source.db'),
      );
      final b = TransactionRepository(
        databasePath: path.join(folder.path, 'target.db'),
      );
      final reminders = ReminderService();
      try {
        await a.save(
          MoneyTransaction(
            id: null,
            type: TransactionType.expense,
            amount: 42000,
            category: 'Makan',
            occurredAt: DateTime.now(),
            note: 'Uji native terisolasi',
          ),
        );
        await a.saveSettings(const AppSettings(darkMode: true));
        await a.saveBill(
          Bill(
            id: null,
            name: 'Internet',
            amount: 250000,
            dueAt: DateTime.now().add(const Duration(days: 2)),
            recurrence: BillRecurrence.monthly,
            reminderMinutes: 60,
            status: BillStatus.active,
          ),
        );
        await a.linkBillSync(
          server: Uri.parse('https://native-test.example.invalid/'),
          userId: '11111111-1111-4111-8111-111111111111',
          email: 'native@example.invalid',
          timezone: 'Etc/UTC',
        );
        await a.payBill((await a.listBills()).single, DateTime.now());
        final binding = (await a.billSyncBinding())!;
        final operation = (await a.nextBillOperation(binding.generation))!;
        await a.close();
        expect(
          (await a.nextBillOperation(
            binding.generation,
            inflightOnly: true,
          ))!.operationId,
          operation.operationId,
        );
        final encrypted = await sealBackup(
          jsonEncode(await a.backupSnapshot()),
          'Frasa-backup-native-pengujian-2026',
        );
        final file = File(path.join(folder.path, 'test.cuenc'));
        await file.writeAsBytes(encrypted, flush: true);
        await b.restoreExternalBackup(
          await openBackup(
            await file.readAsBytes(),
            'Frasa-backup-native-pengujian-2026',
          ),
        );
        expect((await b.getSettings()).darkMode, isTrue);
        expect(await b.listBills(), hasLength(1));
        expect((await b.billRecoverySnapshot())['bill_payments'], hasLength(1));
        expect(
          (await b.nextBillOperation(
            (await b.billSyncBinding())!.generation,
            inflightOnly: true,
          ))!.operationId,
          operation.operationId,
        );
        final scheduled = Bill(
          id: 84722,
          name: 'Pengingat tes native',
          amount: 1000,
          dueAt: DateTime.now().add(const Duration(days: 2)),
          recurrence: BillRecurrence.once,
          reminderMinutes: 60,
          status: BillStatus.active,
        );
        await reminders.schedule(
          scheduled,
          currencyCode: 'IDR',
          locale: const Locale('id', 'ID'),
        );
        expect(await ReminderService().pendingIds(), contains(84722));
        await reminders.cancel(84722);
        expect(await ReminderService().pendingIds(), isNot(contains(84722)));
      } finally {
        await reminders.cancel(84722);
        await a.close();
        await b.close();
        await folder.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
