import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:catat_uang/bill.dart';
import 'package:catat_uang/reminder_service.dart';
import 'package:catat_uang/settings.dart';

class RecordingReminders extends ReminderService {
  final scheduled = <int>[];
  final cancelled = <int>[];
  bool cleared = false;
  int? failId;

  @override
  Future<List<int>> pendingIds() async => [1, 99];
  @override
  Future<void> cancel(int id) async => cancelled.add(id);
  @override
  Future<void> cancelAll() async {
    cleared = true;
  }

  @override
  Future<void> schedule(
    Bill bill, {
    required String currencyCode,
    required Locale locale,
  }) async {
    if (bill.id == failId) throw StateError('Scheduling failed');
    scheduled.add(bill.id!);
  }
}

Bill bill(int id, {int? reminder = 60}) => Bill(
  id: id,
  name: 'Test',
  amount: 100,
  dueAt: DateTime(2030),
  recurrence: BillRecurrence.once,
  reminderMinutes: reminder,
  status: BillStatus.active,
);

void main() {
  test('restores active schedules and cancels orphaned schedules', () async {
    final reminders = RecordingReminders();
    await reminders.reconcile(
      [bill(1), bill(2, reminder: null)],
      settings: const AppSettings(),
      locale: const Locale('id'),
    );
    expect(reminders.scheduled, [1]);
    expect(reminders.cancelled, [99]);
  });

  test('disabled reminders cancel all without scheduling', () async {
    final reminders = RecordingReminders();
    await reminders.reconcile(
      [bill(1)],
      settings: const AppSettings(notificationsEnabled: false),
      locale: const Locale('id'),
    );
    expect(reminders.cleared, isTrue);
    expect(reminders.scheduled, isEmpty);
  });

  test('one failed schedule does not prevent restoring other bills', () async {
    final reminders = RecordingReminders()..failId = 1;
    await expectLater(
      reminders.reconcile(
        [bill(1), bill(2)],
        settings: const AppSettings(),
        locale: const Locale('id'),
      ),
      throwsStateError,
    );
    expect(reminders.scheduled, [2]);
  });
}
