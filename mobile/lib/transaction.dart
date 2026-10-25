enum TransactionType { income, expense }

class MoneyTransaction {
  const MoneyTransaction({
    required this.id,
    required this.type,
    required this.amount,
    required this.category,
    required this.occurredAt,
    this.note = '',
  });

  final int? id;
  final TransactionType type;
  final int amount;
  final String category;
  final DateTime occurredAt;
  final String note;

  Map<String, Object?> toMap() => {
    'id': id,
    'type': type.name,
    'amount': amount,
    'category': category,
    'occurred_at': occurredAt.toIso8601String(),
    'note': note,
  };

  factory MoneyTransaction.fromMap(Map<String, Object?> map) {
    return MoneyTransaction(
      id: map['id'] as int?,
      type: TransactionType.values.byName(map['type']! as String),
      amount: map['amount']! as int,
      category: map['category']! as String,
      occurredAt: DateTime.parse(map['occurred_at']! as String),
      note: map['note'] as String? ?? '',
    );
  }
}
