import 'package:flutter/material.dart';

import 'account_controller.dart';
import 'auth_models.dart';

class AccountSessionsScreen extends StatefulWidget {
  const AccountSessionsScreen({super.key, required this.controller});
  final AccountController controller;
  @override
  State<AccountSessionsScreen> createState() => _AccountSessionsScreenState();
}

class _AccountSessionsScreenState extends State<AccountSessionsScreen> {
  final _items = <AccountSessionInfo>[];
  bool _working = false, _loaded = false, _hasMore = false;
  int _nextOffset = 0;
  String? _notice;
  String date(DateTime value) => value.toLocal().toString().substring(0, 16);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _load();
      }
    });
  }

  Future<void> _load({bool append = false, bool preserveNotice = false}) async {
    if (_working || !mounted) {
      return;
    }
    setState(() {
      _working = true;
      if (!preserveNotice) {
        _notice = null;
      }
    });
    final page = await widget.controller.listSessions(
      offset: append ? _nextOffset : 0,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _working = false;
      if (page == null) {
        _notice =
            widget.controller.message ?? 'Daftar sesi belum dapat diperiksa.';
        return;
      }
      if (!append) {
        _items.clear();
      }
      final seen = {for (final item in _items) item.id};
      _items.addAll(page.items.where((item) => seen.add(item.id)));
      _nextOffset = page.offset + page.items.length;
      _hasMore = page.hasMore;
      _loaded = true;
    });
  }

  Future<void> _revoke(AccountSessionInfo session) async {
    if (_working || session.current) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cabut sesi masuk ini?'),
        content: Text(
          'Sesi yang dibuat ${date(session.createdAt)} akan dicabut. Login tersebut perlu masuk kembali. Catatan lokal tidak dihapus.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cabut sesi'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() {
      _working = true;
      _notice = null;
    });
    final success = await widget.controller.revokeSession(session.id);
    if (!mounted) {
      return;
    }
    setState(() {
      _working = false;
      _notice = success ? 'Sesi dicabut.' : widget.controller.message;
    });
    if (widget.controller.hasSession && widget.controller.verified) {
      await _load(preserveNotice: true);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final account = widget.controller;
      final available = account.canManageSessions && !_working;
      return PopScope(
        canPop: !account.busy,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Sesi masuk'),
            actions: [
              IconButton(
                tooltip: 'Perbarui daftar sesi',
                onPressed: available ? () => _load() : null,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                'Setiap login membuat satu sesi, termasuk beberapa login dari perangkat yang sama. Daftar ini menampilkan waktu masuk dan berakhir, bukan jenis perangkat.',
              ),
              const SizedBox(height: 16),
              if (_working)
                const LinearProgressIndicator(
                  semanticsLabel: 'Memeriksa sesi masuk',
                ),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Semantics(liveRegion: true, child: Text(_notice!)),
                ),
              if (!account.hasSession)
                const Text(
                  'Sesi berakhir. Kembali ke Akun untuk masuk kembali.',
                )
              else if (_loaded && _items.isEmpty)
                const Text(
                  'Tidak ada sesi aktif pada daftar ini. Periksa sesi akun kembali.',
                )
              else
                for (final (index, session) in _items.indexed)
                  Card(
                    key: ValueKey(session.id),
                    child: ListTile(
                      title: Text(
                        session.current
                            ? 'Sesi ini'
                            : 'Sesi masuk ${index + 1}',
                      ),
                      subtitle: Text(
                        'Masuk: ${date(session.createdAt)}\nBerakhir: ${date(session.expiresAt)}',
                      ),
                      trailing: session.current
                          ? const Chip(label: Text('Aktif di sini'))
                          : OutlinedButton(
                              onPressed: available
                                  ? () => _revoke(session)
                                  : null,
                              child: const Text('Cabut'),
                            ),
                    ),
                  ),
              if (_hasMore && account.hasSession)
                TextButton(
                  onPressed: available ? () => _load(append: true) : null,
                  child: const Text('Muat sesi berikutnya'),
                ),
              if (account.hasSession)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text(
                    'Untuk mengakhiri sesi ini, gunakan Keluar dari akun pada halaman Akun. Daftar diperbarui setelah pencabutan.',
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
