import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'main.dart';
import 'transaction_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!const bool.fromEnvironment('DEMO_BUILD')) {
    throw StateError('Build this entrypoint with DEMO_BUILD=true');
  }
  if (const String.fromEnvironment('API_BASE_URL').isNotEmpty) {
    throw StateError('This sample-data demo must remain offline');
  }
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF8C4A32)),
        scaffoldBackgroundColor: const Color(0xFFFFFAF5),
      ),
      home: const DemoLauncher(),
    ),
  );
}

class DemoLauncher extends StatefulWidget {
  const DemoLauncher({super.key});
  @override
  State<DemoLauncher> createState() => _DemoLauncherState();
}

class _DemoLauncherState extends State<DemoLauncher> {
  bool busy = false;
  String? error;
  Future<void> open(bool samples) async {
    setState(() {
      busy = true;
      error = null;
    });
    TransactionRepository? repository;
    try {
      repository = TransactionRepository(
        databasePath: path.join(
          await getDatabasesPath(),
          samples ? 'catat_uang_demo.db' : 'catat_uang_demo_empty.db',
        ),
      );
      if (samples) await repository.seedDemoData(DateTime.now());
      await repository.getSettings();
      if (!mounted) {
        await repository.close();
        return;
      }
      runApp(CatatUangApp(repository: repository, demo: true));
    } catch (_) {
      await repository?.close();
      if (mounted) {
        setState(() {
          busy = false;
          error = 'Demo belum dapat dibuka. Coba lagi.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.account_balance_wallet_outlined,
                size: 64,
                color: Color(0xFF8C4A32),
              ),
              const SizedBox(height: 24),
              Text(
                'Coba Catat Uang',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              const Text(
                'Demo dengan data fiktif. Catat pemasukan, pantau pengeluaran, dan kelola tagihan tanpa internet.',
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: busy ? null : () => open(true),
                icon: const Icon(Icons.explore_outlined),
                label: const Text('Jelajahi data contoh'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: busy ? null : () => open(false),
                child: const Text('Coba dari kosong'),
              ),
              const SizedBox(height: 20),
              const Text(
                'Dua ruang demo terpisah. Catatan tersimpan saat aplikasi ditutup. Build ini tidak terhubung ke server dan tidak mengubah aplikasi Catat Uang reguler.',
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: LinearProgressIndicator(),
                ),
              if (error != null) Text(error!),
            ],
          ),
        ),
      ),
    ),
  );
}
