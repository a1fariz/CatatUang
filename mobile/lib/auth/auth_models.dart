class AuthUser {
  const AuthUser({
    required this.id,
    required this.email,
    this.emailVerified = false,
  });
  final String id;
  final String email;
  final bool emailVerified;

  factory AuthUser.fromJson(Map<String, dynamic> value) {
    final id = value['id'];
    final email = value['email'];
    if (id is! String ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(id) ||
        email is! String ||
        email.length > 254 ||
        !RegExp(r'^[^\s@]+@[^\s@]+$').hasMatch(email)) {
      throw const FormatException('Invalid account response');
    }
    if (value['email_verified'] != null && value['email_verified'] is! bool) {
      throw const FormatException('Invalid email status');
    }
    return AuthUser(
      id: id,
      email: email,
      emailVerified: value['email_verified'] == true,
    );
  }

  Map<String, Object> toJson() => {
    'id': id,
    'email': email,
    'email_verified': emailVerified,
  };
}

class AuthSession {
  const AuthSession({
    required this.token,
    required this.expiresAt,
    required this.user,
  });
  final String token;
  final DateTime expiresAt;
  final AuthUser user;

  factory AuthSession.fromJson(Map<String, dynamic> value) {
    final token = value['access_token'];
    final expiry = value['expires_at'];
    final user = value['user'];
    if (value['token_type'] != 'Bearer' ||
        token is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token) ||
        expiry is! String ||
        user is! Map<String, dynamic>) {
      throw const FormatException('Invalid session response');
    }
    final expiresAt = DateTime.tryParse(expiry);
    if (expiresAt == null || !expiresAt.isUtc) {
      throw const FormatException('Invalid session expiry');
    }
    return AuthSession(
      token: token,
      expiresAt: expiresAt,
      user: AuthUser.fromJson(user),
    );
  }

  Map<String, Object> toJson() => {
    'access_token': token,
    'token_type': 'Bearer',
    'expires_at': expiresAt.toUtc().toIso8601String(),
    'user': user.toJson(),
  };
}

bool validSessionId(Object? value) =>
    value is String &&
    RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ).hasMatch(value) &&
    value != '00000000-0000-0000-0000-000000000000';

class AccountSessionInfo {
  const AccountSessionInfo({
    required this.id,
    required this.current,
    required this.createdAt,
    required this.expiresAt,
  });
  final String id;
  final bool current;
  final DateTime createdAt, expiresAt;
  factory AccountSessionInfo.fromJson(Map<String, dynamic> json) {
    final created = json['created_at'] is String
        ? DateTime.tryParse(json['created_at'] as String)
        : null;
    final expires = json['expires_at'] is String
        ? DateTime.tryParse(json['expires_at'] as String)
        : null;
    if (!validSessionId(json['id']) ||
        json['current'] is! bool ||
        created == null ||
        expires == null ||
        !created.isUtc ||
        !expires.isUtc ||
        !expires.isAfter(created)) {
      throw const FormatException('Invalid account session');
    }
    return AccountSessionInfo(
      id: json['id'] as String,
      current: json['current'] as bool,
      createdAt: created,
      expiresAt: expires,
    );
  }
}

class AccountSessionPage {
  const AccountSessionPage({
    required this.items,
    required this.offset,
    required this.hasMore,
  });
  final List<AccountSessionInfo> items;
  final int offset;
  final bool hasMore;
  factory AccountSessionPage.fromJson(
    Map<String, dynamic> json,
    int expectedOffset,
  ) {
    final rows = json['items'];
    final limit = json['limit'];
    if (rows is! List ||
        limit is! int ||
        limit < 1 ||
        limit > 100 ||
        rows.length > limit ||
        json['offset'] is! int ||
        json['offset'] != expectedOffset ||
        json['has_more'] is! bool ||
        json['has_more'] == true && rows.length != limit) {
      throw const FormatException('Invalid session page');
    }
    final items = rows.map((row) {
      if (row is! Map<String, dynamic>) {
        throw const FormatException('Invalid session item');
      }
      return AccountSessionInfo.fromJson(row);
    }).toList();
    if (items.map((item) => item.id).toSet().length != items.length ||
        items.where((item) => item.current).length > 1) {
      throw const FormatException('Duplicate session');
    }
    return AccountSessionPage(
      items: items,
      offset: expectedOffset,
      hasMore: json['has_more'] as bool,
    );
  }
}

class AuthFailure implements Exception {
  const AuthFailure(this.message, {this.status, this.retryAfter});
  final String message;
  final int? status;
  final Duration? retryAfter;
  @override
  String toString() => message;
}
