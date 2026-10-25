import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:catat_uang/money_format.dart';

void main() {
  test('parses IDR grouping into exact minor units', () {
    expect(
      parseMoneyAmount('1.234.567', 'IDR', const Locale('id', 'ID')),
      1234567,
    );
  });

  test('formats reminders in selected currency and locale', () {
    expect(
      formatMoneyAmount(123456, 'USD', const Locale('en', 'US')),
      r'$1,234.56',
    );
    expect(
      formatMoneyAmount(123456, 'EUR', const Locale('de', 'DE')),
      '1.234,56 €',
    );
  });

  test('parses fractional currency and rejects excess decimals', () {
    expect(
      parseMoneyAmount('1,234.56', 'USD', const Locale('en', 'US')),
      123456,
    );
    expect(parseMoneyAmount('1.234', 'USD', const Locale('en', 'US')), isNull);
    expect(parseMoneyAmount('-1.00', 'USD', const Locale('en', 'US')), isNull);
  });
}
