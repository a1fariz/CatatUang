import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:catat_uang/auth/session_store.dart';

import 'auth_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, String> values;
  setUp(() {
    values = {};
    FlutterSecureStorage.setMockInitialValues(values);
  });

  test(
    'one secure record survives adapter recreation and excludes passwords',
    () async {
      final server = Uri.parse('https://api.example.com/');
      await SecureSessionStore(server: server).write(testSession());
      expect(values, hasLength(1));
      expect(values.values.single, isNot(contains('password')));
      final restored = await SecureSessionStore(server: server).read();
      expect(restored?.token, 'a' * 43);
      expect(restored?.user.id, testUser.id);
    },
  );

  test('credentials for different servers are isolated', () async {
    final development = SecureSessionStore(
      server: Uri.parse('https://dev.example.com/'),
    );
    final production = SecureSessionStore(
      server: Uri.parse('https://api.example.com/'),
    );
    await development.write(testSession());
    expect(await production.read(), isNull);
    values['unrelated_app_value'] = 'keep';
    await production.clear();
    expect((await development.read())?.user.id, testUser.id);
    await development.clear();
    expect(values, {'unrelated_app_value': 'keep'});
  });

  test('corrupted secure record is not silently accepted', () async {
    final store = SecureSessionStore(
      server: Uri.parse('https://api.example.com/'),
    );
    await store.write(testSession());
    values[values.keys.single] = '{bad json';
    await expectLater(store.read(), throwsFormatException);
  });
}
