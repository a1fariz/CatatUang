import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../bill.dart';
import 'sync_models.dart';

bool _zonesReady = false;
tz.Location billZone(String name) {
  if (!_zonesReady) {
    tzdata.initializeTimeZones();
    _zonesReady = true;
  }
  return tz.getLocation(name);
}

DateTime billCalendarDate(DateTime instant, String? zone) =>
    zone == null ? instant : tz.TZDateTime.from(instant, billZone(zone));
DateTime billDueOnDate(DateTime date, String? zone) => zone == null
    ? DateTime(date.year, date.month, date.day, 9)
    : tz.TZDateTime(
        billZone(zone),
        date.year,
        date.month,
        date.day,
        9,
      ).toLocal();
int billDaysLate(Bill bill, DateTime now) {
  final today = billCalendarDate(now, bill.timezone),
      due = billCalendarDate(bill.dueAt, bill.timezone);
  return DateTime.utc(
    today.year,
    today.month,
    today.day,
  ).difference(DateTime.utc(due.year, due.month, due.day)).inDays;
}

DateTime nextZonedBillDue(Bill bill) {
  final zone = billZone(bill.timezone!);
  final local = tz.TZDateTime.from(bill.dueAt, zone);
  var year = local.year, month = local.month, day = local.day;
  switch (bill.recurrence) {
    case BillRecurrence.once:
      return bill.dueAt;
    case BillRecurrence.weekly:
      day += 7;
    case BillRecurrence.monthly:
      month++;
      day = bill.recurrenceDay ?? local.day;
    case BillRecurrence.yearly:
      year++;
      day = bill.recurrenceDay ?? local.day;
  }
  if (bill.recurrence != BillRecurrence.weekly) {
    day = day.clamp(1, DateTime(year, month + 1, 0).day);
  }
  return tz.TZDateTime(
    zone,
    year,
    month,
    day,
    local.hour,
    local.minute,
    local.second,
  ).toLocal();
}

class BillSyncRecord {
  BillSyncRecord.fromJson(Map<String, dynamic> value)
    : json = Map.unmodifiable(value) {
    if (!validSyncId(value['id']) ||
        value['version'] is! int ||
        (value['version'] as int) < 1 ||
        value['deleted'] is! bool ||
        !const ['IDR', 'USD', 'EUR', 'SGD'].contains(value['currency_code']) ||
        value['payments'] is! List ||
        (value['payments'] as List).length > 2000) {
      throw const FormatException('Invalid bill snapshot');
    }
    final model = local(null);
    if (model.name.trim().isEmpty ||
        model.name.runes.length > 80 ||
        model.amount < 1 ||
        model.amount > 9007199254740991 ||
        model.dueAt.year < 2000 ||
        model.dueAt.year > 2100 ||
        model.recurrenceDay! < 1 ||
        model.recurrenceDay! > 31) {
      throw const FormatException('Invalid bill');
    }
    billZone(model.timezone!);
    final ids = <String>{}, dues = <String>{};
    for (final p in payments) {
      if (!validSyncId(p['id']) ||
          p['bill_id'] != id ||
          p['amount_minor'] is! int ||
          (p['amount_minor'] as int) < 1 ||
          p['currency_code'] != currency ||
          !ids.add(p['id'] as String) ||
          !dues.add(
            DateTime.parse(p['due_at'] as String).toUtc().toIso8601String(),
          )) {
        throw const FormatException('Invalid payment');
      }
      DateTime.parse(p['paid_at'] as String);
    }
  }
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String get currency => json['currency_code'] as String;
  int get version => json['version'] as int;
  bool get deleted => json['deleted'] as bool;
  List<Map<String, dynamic>> get payments => (json['payments'] as List)
      .map((v) => Map<String, dynamic>.from(v as Map))
      .toList();
  Bill local(int? id) => Bill(
    id: id,
    name: json['name'] as String,
    amount: json['amount_minor'] as int,
    dueAt: DateTime.parse(json['due_at'] as String).toLocal(),
    recurrence: BillRecurrence.values.byName(json['recurrence'] as String),
    recurrenceDay: json['recurrence_day'] as int,
    reminderMinutes: json['reminder_minutes'] as int?,
    status: BillStatus.values.byName(json['status'] as String),
    paidAt: json['paid_at'] == null
        ? null
        : DateTime.parse(json['paid_at'] as String).toLocal(),
    timezone: json['timezone'] as String,
  );
}
