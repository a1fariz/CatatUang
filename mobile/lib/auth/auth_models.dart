class AuthUser {
  const AuthUser({required this.id, required this.email});
  final String id;
  final String email;

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
    return AuthUser(id: id, email: email);
  }

  Map<String, Object> toJson() => {'id': id, 'email': email};
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

class AuthFailure implements Exception {
  const AuthFailure(this.message, {this.status, this.retryAfter});
  final String message;
  final int? status;
  final Duration? retryAfter;
  @override
  String toString() => message;
}
