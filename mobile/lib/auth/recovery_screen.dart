import 'dart:convert';
import 'package:flutter/material.dart';
import 'account_controller.dart';
import 'auth_api.dart';
import 'auth_models.dart';

class AccountRecoveryScreen extends StatefulWidget {
  const AccountRecoveryScreen({
    super.key,
    required this.controller,
    this.verifyEmail = false,
    this.gateway,
  });
  final AccountController controller;
  final bool verifyEmail;
  final AccountRecoveryGateway? gateway;
  @override
  State<AccountRecoveryScreen> createState() => _AccountRecoveryScreenState();
}

class _AccountRecoveryScreenState extends State<AccountRecoveryScreen> {
  late final _gateway =
      widget.gateway ?? HttpAuthGateway(baseUri: widget.controller.serverUri);
  final _email = TextEditingController(),
      _token = TextEditingController(),
      _password = TextEditingController(),
      _confirm = TextEditingController();
  bool _busy = false;
  String? _message;
  DateTime? _blockedUntil;
  @override
  void initState() {
    super.initState();
    _email.text = widget.controller.user?.email ?? '';
  }

  @override
  void dispose() {
    _email.dispose();
    _token.dispose();
    _password.dispose();
    _confirm.dispose();
    if (widget.gateway == null) _gateway.close();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    if (_blockedUntil?.isAfter(DateTime.now()) ?? false) {
      setState(() => _message = 'Tunggu beberapa saat sebelum mencoba lagi.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on AuthFailure catch (e) {
      _message = e.message;
      if (e.retryAfter != null) {
        _blockedUntil = DateTime.now().add(e.retryAfter!);
      }
    } catch (_) {
      _message = 'Permintaan belum selesai. Coba lagi setelah memeriksa akun.';
    } finally {
      _token.clear();
      _password.clear();
      _confirm.clear();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _request() async {
    if (!widget.verifyEmail &&
        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(_email.text.trim())) {
      setState(() => _message = 'Masukkan alamat email yang valid.');
      return;
    }
    await _run(() async {
      if (widget.verifyEmail) {
        final account = widget.controller;
        final user = account.user;
        if (user == null) throw const AuthFailure('Masuk terlebih dahulu.');
        await account.authorized(
          userId: user.id,
          server: account.serverUri,
          action: (session) => _gateway.requestEmailVerification(session),
        );
      } else {
        await _gateway.requestPasswordReset(_email.text);
      }
      _message =
          'Jika permintaan memenuhi syarat, kode dikirim ke email akun. Periksa kotak masuk dan spam. Kode lama digantikan saat meminta kode baru.';
    });
  }

  Future<void> _submit() async {
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(_token.text.trim())) {
      setState(() => _message = 'Masukkan kode lengkap dari email.');
      return;
    }
    if (!widget.verifyEmail &&
        (_password.text.runes.length < 15 ||
            utf8.encode(_password.text).length > 128 ||
            _password.text != _confirm.text)) {
      setState(
        () => _message =
            'Kata sandi harus minimal 15 karakter, maksimal 128 byte, dan konfirmasi sama.',
      );
      return;
    }
    final token = _token.text.trim(), password = _password.text;
    await _run(() async {
      if (widget.verifyEmail) {
        await _gateway.confirmEmailVerification(token);
        await widget.controller.refresh();
        _message = widget.controller.user?.emailVerified == true
            ? 'Email terverifikasi.'
            : 'Kode diterima. Periksa ulang status akun saat terhubung.';
      } else {
        await _gateway.confirmPasswordReset(token, password);
        _message =
            'Kata sandi diperbarui dan semua sesi dicabut. Kembali lalu masuk dengan kata sandi baru. Data lokal tetap tersimpan.';
      }
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          widget.verifyEmail ? 'Verifikasi email' : 'Lupa kata sandi',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Server: ${widget.controller.serverUri.origin}'),
          const Text(
            'Jangan bagikan kode. Masukkan hanya kode yang Anda minta untuk server ini.',
          ),
          TextField(
            controller: _email,
            enabled: !_busy && !widget.verifyEmail,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email akun'),
          ),
          OutlinedButton(
            onPressed: _busy ? null : _request,
            child: const Text('Kirim kode email'),
          ),
          TextField(
            controller: _token,
            enabled: !_busy,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Kode dari email'),
          ),
          if (!widget.verifyEmail) ...[
            TextField(
              controller: _password,
              enabled: !_busy,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Kata sandi baru'),
            ),
            TextField(
              controller: _confirm,
              enabled: !_busy,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Konfirmasi kata sandi baru',
              ),
            ),
          ],
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: Text(
              widget.verifyEmail ? 'Verifikasi kode' : 'Reset kata sandi',
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_message != null) Text(_message!),
        ],
      ),
    ),
  );
}
