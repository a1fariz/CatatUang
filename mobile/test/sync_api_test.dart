import 'dart:async';
import 'dart:convert';

import 'package:catat_uang/auth/auth_models.dart';
import 'package:catat_uang/sync/sync_api.dart';
import 'package:catat_uang/sync/sync_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'sync_fakes.dart';

void main() {
  final base = Uri.parse('https://api.example.com/');
  test(
    'dataset discovery validates identity and sync sends the pinned header',
    () async {
      final identity = syncId();
      final api = HttpTransactionSyncGateway(
        baseUri: base,
        clientFactory: () => MockClient((request) async {
          if (request.url.path == '/v1/sync/state') {
            expect(request.headers.containsKey('X-Sync-Dataset'), isFalse);
            return http.Response(
              jsonEncode({'dataset_id': identity}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          expect(request.headers['X-Sync-Dataset'], identity);
          return http.Response(
            '{"items":[],"cursor":0,"has_more":false}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(api.close);
      expect(await api.datasetId('secret'), identity);
      expect((await api.pull('secret', 0, dataset: identity)).cursor, 0);
    },
  );
  test(
    'sync HTTP sends a fixed operation, no redirects or implicit retries',
    () async {
      var calls = 0;
      final op = SyncOperation({
        'operation_id': syncId(),
        'remote_id': syncId(),
        'base_version': 0,
        'deleted': 0,
        'payload': jsonEncode(transactionPayload(localTransaction(), 'IDR')),
      });
      final api = HttpTransactionSyncGateway(
        baseUri: base,
        clientFactory: () => MockClient((request) async {
          calls++;
          expect(request.method, 'POST');
          expect(request.url.path, '/v1/sync/transactions');
          expect(request.followRedirects, isFalse);
          expect(request.headers['Authorization'], 'Bearer secret');
          expect(jsonDecode(request.body), op.toJson());
          return http.Response(
            jsonEncode(operationReceipt(op).json),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(api.close);
      expect((await api.push('secret', op)).version, 1);
      expect(calls, 1);
    },
  );
  test(
    'HTTP failures retain actionable status without reflecting server messages',
    () async {
      for (final status in [401, 409, 422, 503, 302]) {
        var calls = 0;
        final api = HttpTransactionSyncGateway(
          baseUri: base,
          clientFactory: () => MockClient((_) async {
            calls++;
            return http.Response(
              '{"error":{"code":"sync_reset_required","message":"private diagnostic"}}',
              status,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        try {
          await expectLater(
            api.pull('secret', 0),
            throwsA(
              status == 401
                  ? isA<AuthFailure>().having((e) => e.status, 'status', 401)
                  : isA<SyncFailure>()
                        .having((e) => e.status, 'status', status)
                        .having(
                          (e) => e.message,
                          'safe message',
                          isNot(contains('private diagnostic')),
                        ),
            ),
          );
          expect(calls, 1);
        } finally {
          api.close();
        }
      }
    },
  );
  test(
    'timeouts, malformed JSON, oversized bodies, and wrong content type fail safely',
    () async {
      for (final response in [
        http.Response(
          'not json',
          200,
          headers: {'content-type': 'application/json'},
        ),
        http.Response(
          'x' * 1048577,
          200,
          headers: {'content-type': 'application/json'},
        ),
        http.Response('{}', 200, headers: {'content-type': 'text/html'}),
      ]) {
        final api = HttpTransactionSyncGateway(
          baseUri: base,
          clientFactory: () => MockClient((_) async => response),
        );
        await expectLater(api.pull('secret', 0), throwsA(isA<SyncFailure>()));
        api.close();
      }
      final api = HttpTransactionSyncGateway(
        baseUri: base,
        timeout: const Duration(milliseconds: 10),
        clientFactory: () =>
            MockClient((_) => Completer<http.Response>().future),
      );
      await expectLater(api.pull('secret', 0), throwsA(isA<SyncFailure>()));
      api.close();
    },
  );
  test(
    'page parser rejects invalid cursors, unordered sequences and malformed money',
    () {
      final good = {
        'items': [
          {'sequence': 1, 'record': remoteRecord().json},
        ],
        'cursor': 1,
        'has_more': false,
      };
      expect(SyncPage.fromJson(good, 0).items, hasLength(1));
      for (final value in [
        {...good, 'cursor': -1},
        {...good, 'cursor': 0},
        {...good, 'has_more': null},
        {...good, 'items': [], 'cursor': 1, 'has_more': true},
        {
          ...good,
          'items': [
            {'sequence': 1, 'record': remoteRecord().json},
            {'sequence': 1, 'record': remoteRecord().json},
          ],
        },
        {
          ...good,
          'items': [
            {
              'sequence': 1,
              'record': {...remoteRecord().json, 'amount_minor': 1.5},
            },
          ],
        },
        {
          ...good,
          'items': [
            {
              'sequence': 1,
              'record': {...remoteRecord().json, 'occurred_on': '2026-02-30'},
            },
          ],
        },
      ]) {
        expect(() => SyncPage.fromJson(value, 0), throwsFormatException);
      }
    },
  );
}
