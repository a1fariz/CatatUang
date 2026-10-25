import 'dart:convert';
import 'dart:math';

import '../transaction.dart';

String syncId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

bool validSyncId(Object? value) =>
    value is String &&
    RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ).hasMatch(value) &&
    value != '00000000-0000-0000-0000-000000000000';

class SyncFailure implements Exception {
  const SyncFailure(this.message, {this.status, this.code});
  final String message;
  final int? status;
  final String? code;
}

Map<String, Object?> transactionPayload(
  MoneyTransaction value,
  String currency,
) => {
  'type': value.type.name,
  'amount_minor': value.amount,
  'currency_code': currency,
  'category': value.category,
  'occurred_on':
      '${value.occurredAt.year.toString().padLeft(4, '0')}-${value.occurredAt.month.toString().padLeft(2, '0')}-${value.occurredAt.day.toString().padLeft(2, '0')}',
  'note': value.note,
};

class SyncRecord {
  SyncRecord.fromJson(Map<String, dynamic> value)
    : json = Map.unmodifiable(value) {
    final amount = value['amount_minor'];
    final version = value['version'];
    final date = value['occurred_on'];
    final note = value['note'];
    const categories = {
      'income': ['Gaji', 'Bonus', 'Lainnya'],
      'expense': ['Makan', 'Transportasi', 'Belanja', 'Tagihan', 'Lainnya'],
    };
    if (!validSyncId(value['id']) ||
        amount is! int ||
        amount <= 0 ||
        amount > 9007199254740991 ||
        version is! int ||
        version < 1 ||
        version > 9007199254740991 ||
        value['deleted'] is! bool ||
        !const ['IDR', 'USD', 'EUR', 'SGD'].contains(value['currency_code']) ||
        !(categories[value['type']]?.contains(value['category']) ?? false) ||
        date is! String ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
        date.compareTo('2000-01-01') < 0 ||
        date.compareTo('2100-12-31') > 0 ||
        DateTime.tryParse(date)?.toIso8601String().substring(0, 10) != date ||
        note is! String ||
        note.runes.length > 200 ||
        note.contains('\u0000')) {
      throw const FormatException('Invalid sync record');
    }
  }
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  int get version => json['version'] as int;
  bool get deleted => json['deleted'] as bool;
  String get currency => json['currency_code'] as String;
  MoneyTransaction local(int? id) => MoneyTransaction(
    id: id,
    type: TransactionType.values.byName(json['type'] as String),
    amount: json['amount_minor'] as int,
    category: json['category'] as String,
    occurredAt: DateTime.parse(json['occurred_on'] as String),
    note: json['note'] as String,
  );
}

class SyncPage {
  SyncPage({required this.items, required this.cursor, required this.hasMore});
  factory SyncPage.fromJson(Map<String, dynamic> json, int after) {
    final items = json['items'];
    final cursor = json['cursor'];
    if (items is! List ||
        items.length > 100 ||
        cursor is! int ||
        cursor < after ||
        cursor > 9007199254740991 ||
        json['has_more'] is! bool) {
      throw const FormatException('Invalid sync page');
    }
    var previous = after;
    final records = <SyncRecord>[];
    for (final item in items) {
      if (item is! Map<String, dynamic> ||
          item['sequence'] is! int ||
          (item['sequence'] as int) <= previous ||
          (item['sequence'] as int) > cursor ||
          item['record'] is! Map<String, dynamic>) {
        throw const FormatException('Invalid sync sequence');
      }
      previous = item['sequence'] as int;
      records.add(SyncRecord.fromJson(item['record'] as Map<String, dynamic>));
    }
    if (json['has_more'] == true && (items.isEmpty || cursor != previous)) {
      throw const FormatException('Invalid sync continuation');
    }
    return SyncPage(
      items: records,
      cursor: cursor,
      hasMore: json['has_more'] as bool,
    );
  }
  final List<SyncRecord> items;
  final int cursor;
  final bool hasMore;
}

class SyncBinding {
  SyncBinding(Map<String, Object?> row)
    : generation = row['generation'] as String,
      server = row['server'] as String,
      userId = row['user_id'] as String,
      email = row['email'] as String,
      currency = row['currency'] as String,
      cursor = row['cursor'] as int,
      lastSuccess = row['last_success'] as String?,
      datasetId = row['dataset_id'] as String?;
  final String? datasetId;
  final String generation, server, userId, email, currency;
  final int cursor;
  final String? lastSuccess;
}

class SyncOperation {
  SyncOperation(Map<String, Object?> row)
    : operationId = row['operation_id'] as String,
      remoteId = row['remote_id'] as String,
      baseVersion = row['base_version'] as int,
      deleted = row['deleted'] == 1,
      payload = row['payload'] == null
          ? null
          : jsonDecode(row['payload'] as String) as Map<String, dynamic>;
  final String operationId, remoteId;
  final int baseVersion;
  final bool deleted;
  final Map<String, dynamic>? payload;
  Map<String, Object?> toJson() => {
    'operation_id': operationId,
    'id': remoteId,
    'base_version': baseVersion,
    'deleted': deleted,
    'payload': payload,
  };
}

class SyncIssue {
  SyncIssue({
    required this.remoteId,
    required this.message,
    this.server,
    this.local,
  });
  final String remoteId, message;
  final SyncRecord? server;
  final MoneyTransaction? local;
}
