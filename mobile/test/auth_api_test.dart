import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:catat_uang/auth/auth_api.dart';
import 'package:catat_uang/auth/auth_models.dart';

import 'auth_fakes.dart';

void main() {
  test('configuration permits HTTPS and debug loopback only', () {
    expect(configuredApiUri(''), isNull);
    expect(
      configuredApiUri('https://api.example.com').toString(),
      'https://api.example.com/',
    );
    expect(
      configuredApiUri('http://10.0.2.2:8080', allowLocalHttp: true)?.host,
      '10.0.2.2',
    );
    for (final url in [
      'http://example.com',
      'https://user:secret@example.com',
      'https://example.com/?token=secret',
      'https://example.com/#secret',
      'ftp://example.com',
      'not-a-url',
    ]) {
      expect(
        () => configuredApiUri(url, allowLocalHttp: true),
        throwsFormatException,
      );
    }
    expect(
      () => configuredApiUri('http://localhost:8080', allowLocalHttp: false),
      throwsFormatException,
    );
  });

  test(
    'authentication uses exact contract without retries or redirects',
    () async {
      var calls = 0;
      final api = HttpAuthGateway(
        baseUri: Uri.parse('https://api.example.com/'),
        clientFactory: () => MockClient((request) async {
          calls++;
          expect(request.url.path, '/v1/auth/register');
          expect(request.url.query, isEmpty);
          expect(request.followRedirects, isFalse);
          expect(request.headers.containsKey('authorization'), isFalse);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body, {
            'email': 'test@example.com',
            'password': '  password-with-spaces  ',
          });
          return http.Response(
            jsonEncode(testSession().toJson()),
            201,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(api.close);
      final session = await api.authenticate(
        ' Test@Example.com ',
        '  password-with-spaces  ',
        register: true,
      );
      expect(session.user.id, testUser.id);
      expect(calls, 1);
    },
  );

  test('me and logout send token only in Authorization header', () async {
    final paths = <String>[];
    final api = HttpAuthGateway(
      baseUri: Uri.parse('https://api.example.com/'),
      clientFactory: () => MockClient((request) async {
        paths.add(request.url.path);
        expect(request.headers['Authorization'], 'Bearer ${'a' * 43}');
        expect(request.url.toString(), isNot(contains('a' * 43)));
        if (request.url.path == '/v1/me') {
          return http.Response(
            jsonEncode(testUser.toJson()),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 204);
      }),
    );
    addTearDown(api.close);
    expect((await api.me('a' * 43)).email, testUser.email);
    await api.logout('a' * 43, all: true);
    expect(paths, ['/v1/me', '/v1/auth/logout-all']);
  });

  for (final status in [401, 409, 422, 429, 302, 500]) {
    test('HTTP $status does not echo untrusted server body', () async {
      final api = HttpAuthGateway(
        baseUri: Uri.parse('https://api.example.com/'),
        clientFactory: () => MockClient(
          (request) async => http.Response(
            'SECRET_SERVER_BODY',
            status,
            headers: {'retry-after': '60'},
          ),
        ),
      );
      addTearDown(api.close);
      try {
        await api.authenticate(
          'test@example.com',
          'password-untuk-test',
          register: false,
        );
        fail('expected error');
      } on AuthFailure catch (failure) {
        expect(failure.status, status);
        expect(failure.toString(), isNot(contains('SECRET')));
        if (status == 429) {
          expect(failure.retryAfter, const Duration(seconds: 60));
        }
      }
    });
  }

  for (final body in [
    '<html>proxy page</html>',
    '{}',
    '[]',
    '{"x":"${'a' * 65536}"}',
  ]) {
    test(
      'malformed or oversized session response is rejected (${body.length})',
      () async {
        final api = HttpAuthGateway(
          baseUri: Uri.parse('https://api.example.com/'),
          clientFactory: () => MockClient(
            (request) async => http.Response(
              body,
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );
        addTearDown(api.close);
        await expectLater(
          api.authenticate(
            'test@example.com',
            'password-untuk-test',
            register: false,
          ),
          throwsA(isA<AuthFailure>()),
        );
      },
    );
  }

  test('network request has a finite deadline', () async {
    final pending = Completer<http.Response>();
    final api = HttpAuthGateway(
      baseUri: Uri.parse('https://api.example.com/'),
      timeout: const Duration(milliseconds: 5),
      clientFactory: () => MockClient((request) => pending.future),
    );
    addTearDown(api.close);
    await expectLater(api.me('a' * 43), throwsA(isA<AuthFailure>()));
    pending.complete(http.Response('{}', 200));
  });
}
