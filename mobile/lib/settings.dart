class AppSettings {
  const AppSettings({
    this.currencyCode = 'IDR',
    this.monthStartDay = 1,
    this.notificationsEnabled = true,
    this.darkMode = false,
  });

  final String currencyCode;
  final int monthStartDay;
  final bool notificationsEnabled;
  final bool darkMode;

  AppSettings copyWith({
    String? currencyCode,
    int? monthStartDay,
    bool? notificationsEnabled,
    bool? darkMode,
  }) => AppSettings(
    currencyCode: currencyCode ?? this.currencyCode,
    monthStartDay: monthStartDay ?? this.monthStartDay,
    notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
    darkMode: darkMode ?? this.darkMode,
  );

  Map<String, Object?> toMap() => {
    'id': 1,
    'currency_code': currencyCode,
    'month_start_day': monthStartDay,
    'notifications_enabled': notificationsEnabled ? 1 : 0,
    'dark_mode': darkMode ? 1 : 0,
  };

  factory AppSettings.fromMap(Map<String, Object?> map) => AppSettings(
    currencyCode: map['currency_code']! as String,
    monthStartDay: map['month_start_day']! as int,
    notificationsEnabled: map['notifications_enabled'] == 1,
    darkMode: map['dark_mode'] == 1,
  );
}

DateTime periodStartFor(DateTime date, int monthStartDay) {
  final day = monthStartDay.clamp(1, 28);
  if (date.day >= day) return DateTime(date.year, date.month, day);
  return DateTime(date.year, date.month - 1, day);
}
