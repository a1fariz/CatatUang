import 'dart:convert';
import 'dart:io';

// Captures the running Android UI without composing or editing screenshots.
// Only a fresh disposable emulator and the dedicated demo package are accepted.
Future<void> main(List<String> args) async {
  if (args.length != 2 || !args[0].startsWith('emulator-')) {
    throw ArgumentError(
      'Usage: dart tool/capture_demo.dart emulator-SERIAL output-directory',
    );
  }
  final device = args[0];
  final out = await Directory(args[1]).create(recursive: true);
  const package = 'dev.catatuang.catat_uang.demo';
  Future<ProcessResult> adb(List<String> command) async {
    final result = await Process.run('adb', ['-s', device, ...command]);
    if (result.exitCode != 0) {
      throw StateError('adb failed: ${command.take(3).join(' ')}');
    }
    return result;
  }

  final state = await adb(['get-state']);
  if (state.stdout.toString().trim() != 'device') {
    throw StateError('Emulator not ready');
  }
  final packages = (await adb([
    'shell',
    'pm',
    'list',
    'packages',
    'dev.catatuang.catat_uang',
  ])).stdout.toString();
  if (const LineSplitter()
      .convert(packages)
      .contains('package:dev.catatuang.catat_uang')) {
    throw StateError('Regular app present; refusing capture');
  }
  if (!const LineSplitter().convert(packages).contains('package:$package')) {
    throw StateError('Demo APK missing');
  }
  Future<String> ui() async {
    const tree = '/data/local/tmp/catatuang-demo-ui.xml';
    for (var attempt = 0; attempt < 6; attempt++) {
      await adb(['shell', 'rm', '-f', tree]);
      final dump = await adb([
        'shell',
        'uiautomator',
        'dump',
        '--compressed',
        tree,
      ]);
      final result = await Process.run('adb', [
        '-s',
        device,
        'shell',
        'cat',
        tree,
      ]);
      final xml = result.stdout.toString();
      if (result.exitCode == 0 && xml.contains('<hierarchy')) return xml;
      stdout.writeln(
        'Waiting for UI hierarchy (${attempt + 1}/6): ${dump.stdout.toString().trim()}',
      );
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw StateError('Android accessibility hierarchy did not become ready');
  }

  Future<void> tap(String label, {bool scroll = false}) async {
    for (var attempt = 0; attempt < (scroll ? 7 : 4); attempt++) {
      final xml = await ui();
      for (final node in RegExp(r'<node\b[^>]*>').allMatches(xml)) {
        final value = node.group(0)!;
        final labels = RegExp(r'(?:text|content-desc)="([^"]*)"')
            .allMatches(value)
            .map(
              (m) => m[1]!.replaceAll('&#10;', '\n').replaceAll('&amp;', '&'),
            );
        if (!labels.any((text) => text.split('\n').contains(label))) continue;
        final bounds = RegExp(
          r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',
        ).firstMatch(value);
        if (bounds == null) continue;
        final x1 = int.parse(bounds[1]!), y1 = int.parse(bounds[2]!);
        final x2 = int.parse(bounds[3]!), y2 = int.parse(bounds[4]!);
        if (x2 <= x1 || y2 <= y1) continue;
        await adb([
          'shell',
          'input',
          'tap',
          '${(x1 + x2) ~/ 2}',
          '${(y1 + y2) ~/ 2}',
        ]);
        await Future<void>.delayed(const Duration(seconds: 2));
        return;
      }
      if (scroll) {
        await adb([
          'shell',
          'input',
          'swipe',
          '540',
          '1450',
          '540',
          '600',
          '350',
        ]);
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw StateError('Demo control not found: $label');
  }

  Future<void> shot(String name) async {
    final result = await Process.run('adb', [
      '-s',
      device,
      'exec-out',
      'screencap',
      '-p',
    ], stdoutEncoding: null);
    if (result.exitCode != 0) throw StateError('Screenshot failed');
    await File(
      '${out.path}/$name.png',
    ).writeAsBytes(result.stdout as List<int>);
    await File('${out.path}/$name.xml').writeAsString(await ui());
  }

  Future<void> launch() async {
    await adb([
      'shell',
      'am',
      'start',
      '-n',
      '$package/dev.catatuang.catat_uang.MainActivity',
    ]);
    await Future<void>.delayed(const Duration(seconds: 3));
  }

  Future<void> enterAmount() async {
    final xml = await ui();
    final node = RegExp(
      r'<node\b[^>]*class="android.widget.EditText"[^>]*>',
    ).firstMatch(xml);
    if (node == null) throw StateError('Amount text field absent');
    final bounds = RegExp(
      r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',
    ).firstMatch(node.group(0)!);
    if (bounds == null) throw StateError('Amount field bounds absent');
    final x = (int.parse(bounds[1]!) + int.parse(bounds[3]!)) ~/ 2;
    final y = (int.parse(bounds[2]!) + int.parse(bounds[4]!)) ~/ 2;
    await adb(['shell', 'input', 'tap', '$x', '$y']);
    await Future<void>.delayed(const Duration(seconds: 1));
    await adb(['shell', 'input', 'text', '12345']);
    await adb(['shell', 'input', 'keyevent', '4']);
    await Future<void>.delayed(const Duration(seconds: 1));
  }

  await adb(['shell', 'svc', 'wifi', 'disable']);
  await adb(['shell', 'svc', 'data', 'disable']);
  await launch();
  await shot('01-demo-launcher');
  // This is an actual 120-second Android screenrecord, without fabricated UI.
  final record = await Process.start('adb', [
    '-s',
    device,
    'shell',
    'screenrecord',
    '--size',
    '720x1280',
    '--bit-rate',
    '2000000',
    '--time-limit',
    '120',
    '/sdcard/catatuang-demo.mp4',
  ]);
  final recordStdout = record.stdout.drain<void>();
  final recordStderr = record.stderr.drain<void>();
  final clock = Stopwatch()..start();
  Future<void> holdUntil(int seconds) async {
    final remaining = Duration(seconds: seconds) - clock.elapsed;
    if (!remaining.isNegative) await Future<void>.delayed(remaining);
  }

  try {
    await holdUntil(4);
    await tap('Jelajahi data contoh');
    await shot('02-catatan-contoh');
    final before = await ui();
    if (!before.contains('Gaji') && !before.contains('contoh')) {
      throw StateError('Sample ledger not visible');
    }
    await holdUntil(18);
    await tap('Tambah transaksi');
    await shot('03-form-transaksi');
    await enterAmount();
    await tap('Simpan transaksi', scroll: true);
    await holdUntil(30);
    await tap('Tagihan');
    await shot('04-tagihan-contoh');
    await holdUntil(43);
    await tap('Pengaturan');
    await shot('05-pengaturan');
    await holdUntil(56);
    await tap('Backup file terenkripsi', scroll: true);
    await shot('06-backup');
    await holdUntil(70);
    await adb(['shell', 'input', 'keyevent', '4']);
    await tap('Catatan');
    // Force-stop/reopen only the isolated demo, while network stays disabled.
    await adb(['shell', 'am', 'force-stop', package]);
    await launch();
    await tap('Jelajahi data contoh');
    final after = await ui();
    if (!after.contains('12,345') && !after.contains('12.345')) {
      throw StateError('Ledger did not survive restart');
    }
    await shot('07-offline-setelah-restart');
    await holdUntil(88);
    await adb(['shell', 'am', 'force-stop', package]);
    await launch();
    await tap('Coba dari kosong');
    await shot('08-panduan-pertama');
    await holdUntil(104);
    await tap('Catat transaksi pertama', scroll: true);
    await shot('09-form-pertama');
    await holdUntil(121);
    final exit = await record.exitCode.timeout(const Duration(seconds: 15));
    await recordStdout;
    await recordStderr;
    if (exit != 0) throw StateError('Android screenrecord failed');
    await adb([
      'pull',
      '/sdcard/catatuang-demo.mp4',
      '${out.path}/catat-uang-demo-2menit.mp4',
    ]);
    await File('${out.path}/evidence.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'captured_at': DateTime.now().toUtc().toIso8601String(),
        'device': device,
        'platform': 'Android emulator',
        'package': package,
        'media': 'Unedited Android screenshots and screenrecord; no audio',
        'network': 'Wi-Fi and cellular disabled on disposable emulator',
        'sample_restart_persistence': true,
        'offline_transaction_created_and_retained_amount_idr': 12345,
        'not_demonstrated': [
          'physical Android',
          'SAF export/restore',
          'notification delivery',
          'two physical device synchronization',
          'cloud synchronization in demo APK',
        ],
      }),
    );
  } finally {
    record.kill();
  }
}
