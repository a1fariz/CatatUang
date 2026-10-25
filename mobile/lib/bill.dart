enum BillRecurrence { once, weekly, monthly, yearly }

enum BillStatus { active, paid, cancelled }

class Bill {
  const Bill({
    required this.id,
    required this.name,
    required this.amount,
    required this.dueAt,
    required this.recurrence,
    this.recurrenceDay,
    required this.reminderMinutes,
    required this.status,
    this.paidAt,
  });

  final int? id;
  final String name;
  final int amount;
  final DateTime dueAt;
  final BillRecurrence recurrence;
  final int? recurrenceDay;
  final int? reminderMinutes;
  final BillStatus status;
  final DateTime? paidAt;

  Bill copyWith({DateTime? dueAt, bool clearReminder = false}) => Bill(
    id: id,
    name: name,
    amount: amount,
    dueAt: dueAt ?? this.dueAt,
    recurrence: recurrence,
    recurrenceDay: recurrenceDay,
    reminderMinutes: clearReminder ? null : reminderMinutes,
    status: status,
    paidAt: paidAt,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'amount': amount,
    'due_at': dueAt.toIso8601String(),
    'recurrence': recurrence.name,
    'recurrence_day': recurrenceDay ?? dueAt.day,
    'reminder_minutes': reminderMinutes,
    'status': status.name,
    'paid_at': paidAt?.toIso8601String(),
  };

  factory Bill.fromMap(Map<String, Object?> map) {
    final dueAt = DateTime.parse(map['due_at']! as String);
    return Bill(
      id: map['id'] as int?,
      name: map['name']! as String,
      amount: map['amount']! as int,
      dueAt: dueAt,
      recurrence: BillRecurrence.values.byName(map['recurrence']! as String),
      recurrenceDay: map['recurrence_day'] as int? ?? dueAt.day,
      reminderMinutes: map['reminder_minutes'] as int?,
      status: BillStatus.values.byName(map['status']! as String),
      paidAt: map['paid_at'] == null
          ? null
          : DateTime.parse(map['paid_at']! as String),
    );
  }
}

DateTime nextDueDate(
  DateTime dueAt,
  BillRecurrence recurrence, {
  int? recurrenceDay,
}) {
  return switch (recurrence) {
    BillRecurrence.once => dueAt,
    BillRecurrence.weekly => DateTime(
      dueAt.year,
      dueAt.month,
      dueAt.day + 7,
      dueAt.hour,
      dueAt.minute,
    ),
    BillRecurrence.monthly => _sameDayInMonth(
      dueAt,
      dueAt.year,
      dueAt.month + 1,
      recurrenceDay ?? dueAt.day,
    ),
    BillRecurrence.yearly => _sameDayInMonth(
      dueAt,
      dueAt.year + 1,
      dueAt.month,
      recurrenceDay ?? dueAt.day,
    ),
  };
}

DateTime _sameDayInMonth(
  DateTime source,
  int year,
  int month,
  int recurrenceDay,
) {
  final firstDay = DateTime(year, month);
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(
    firstDay.year,
    firstDay.month,
    recurrenceDay.clamp(1, lastDay),
    source.hour,
    source.minute,
  );
}
