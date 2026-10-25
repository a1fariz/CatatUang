import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'money_format.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

import 'bill.dart';
import 'settings.dart';

class ReminderService {
  ReminderService({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    timezone_data.initializeTimeZones();
    final localTimezone = await FlutterTimezone.getLocalTimezone();
    timezone.setLocalLocation(timezone.getLocation(localTimezone.identifier));
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    _initialized = true;
  }

  Future<bool> requestPermission() async {
    await initialize();
    if (kIsWeb) return false;
    if (defaultTargetPlatform == TargetPlatform.android) {
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      return granted ?? false;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      return granted ?? false;
    }
    return false;
  }

  Future<void> schedule(
    Bill bill, {
    required String currencyCode,
    required Locale locale,
  }) async {
    final id = bill.id;
    final offset = bill.reminderMinutes;
    if (id == null || offset == null || bill.status != BillStatus.active) {
      return;
    }
    await initialize();
    final scheduledAt = bill.dueAt.subtract(Duration(minutes: offset));
    if (!scheduledAt.isAfter(DateTime.now())) {
      await cancel(id);
      return;
    }
    await _plugin.zonedSchedule(
      id: id,
      scheduledDate: timezone.TZDateTime.from(scheduledAt, timezone.local),
      title: 'Tagihan jatuh tempo',
      body:
          '${bill.name} · ${formatMoneyAmount(bill.amount, currencyCode, locale)}',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'bill_reminders',
          'Pengingat tagihan',
          channelDescription: 'Pengingat tanggal jatuh tempo tagihan.',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: 'bill:$id',
    );
  }

  Future<List<int>> pendingIds() async {
    await initialize();
    return (await _plugin.pendingNotificationRequests())
        .map((request) => request.id)
        .toList();
  }

  // Restore schedules from SQLite without requesting permission on startup.
  Future<void> reconcile(
    List<Bill> bills, {
    required AppSettings settings,
    required Locale locale,
  }) async {
    if (!settings.notificationsEnabled) {
      await cancelAll();
      return;
    }
    final active = bills
        .where(
          (bill) =>
              bill.id != null &&
              bill.status == BillStatus.active &&
              bill.reminderMinutes != null,
        )
        .toList();
    final ids = active.map((bill) => bill.id!).toSet();
    var failed = false;
    for (final id in await pendingIds()) {
      if (!ids.contains(id)) {
        try {
          await cancel(id);
        } catch (_) {
          failed = true;
        }
      }
    }
    for (final bill in active) {
      try {
        await schedule(
          bill,
          currencyCode: settings.currencyCode,
          locale: locale,
        );
      } catch (_) {
        failed = true;
      }
    }
    if (failed) throw StateError('Some reminders could not be restored.');
  }

  Future<void> cancel(int id) async {
    await initialize();
    await _plugin.cancel(id: id);
  }

  Future<void> cancelAll() async {
    await initialize();
    await _plugin.cancelAll();
  }
}
