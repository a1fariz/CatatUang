import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

int currencyFractionDigits(String currencyCode) =>
    currencyCode == 'IDR' ? 0 : 2;

int? parseMoneyAmount(String input, String currencyCode, Locale locale) {
  final symbols = NumberFormat.decimalPattern(locale.toString()).symbols;
  final grouping = symbols.GROUP_SEP;
  final decimal = symbols.DECIMAL_SEP;
  var normalized = input
      .trim()
      .replaceAll('\u00a0', '')
      .replaceAll('\u202f', '');
  if (grouping.isNotEmpty) normalized = normalized.replaceAll(grouping, '');
  if (decimal != '.') normalized = normalized.replaceAll(decimal, '.');
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(normalized)) return null;

  final parts = normalized.split('.');
  final fractionDigits = currencyFractionDigits(currencyCode);
  if (parts.length > 1 && parts.last.length > fractionDigits) return null;
  final scale = BigInt.from(10).pow(fractionDigits);
  final fraction = parts.length == 1
      ? BigInt.zero
      : BigInt.parse(parts.last.padRight(fractionDigits, '0'));
  final minorUnits = BigInt.parse(parts.first) * scale + fraction;
  if (minorUnits <= BigInt.zero || minorUnits > BigInt.from(9007199254740991)) {
    return null;
  }
  return minorUnits.toInt();
}

String formatMoneyAmount(int amountMinor, String currencyCode, Locale locale) {
  final fractionDigits = currencyFractionDigits(currencyCode);
  return NumberFormat.currency(
    name: currencyCode,
    symbol: currencySymbol(currencyCode),
    locale: locale.toString(),
    decimalDigits: fractionDigits,
  ).format(amountMinor / BigInt.from(10).pow(fractionDigits).toInt());
}

String currencySymbol(String currencyCode) => switch (currencyCode) {
  'USD' => '\$',
  'EUR' => '€',
  'SGD' => 'S\$',
  _ => 'Rp',
};
