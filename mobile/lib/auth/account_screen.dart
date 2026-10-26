import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'account_controller.dart';
import 'password_screen.dart';
import 'sessions_screen.dart';
import 'recovery_screen.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.controller});
  final AccountController controller;
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _register = false;
  bool _showPassword = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!widget.controller.canAuthenticate || !_form.currentState!.validate()) {
      return;
    }
    FocusScope.of(context).unfocus();
    final success = await widget.controller.authenticate(
      _email.text,
      _password.text,
      register: _register,
    );
    if (!mounted) return;
    if (success) {
      _password.clear();
      _confirmation.clear();
      TextInput.finishAutofillContext(shouldSave: true);
    }
  }

  Future<void> _logout(bool all) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(all ? 'Keluar dari semua perangkat?' : 'Keluar dari akun?'),
        content: const Text('Catatan lokal tetap tersimpan di perangkat ini.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Keluar'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      _password.clear();
      _confirmation.clear();
      await widget.controller.logout(all: all);
    }
  }

  Future<void> _changePassword() async {
    widget.controller.clearMessage();
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ChangePasswordScreen(controller: widget.controller),
      ),
    );
    if (changed == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Kata sandi diperbarui. Perangkat lain perlu masuk kembali.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final account = widget.controller;
      return PopScope(
        canPop: !account.busy,
        child: Scaffold(
          appBar: AppBar(title: const Text('Akun')),
          body: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Icon(Icons.account_circle_outlined, size: 56),
              const SizedBox(height: 16),
              Text(
                account.hasSession
                    ? 'Akun tersimpan'
                    : _register
                    ? 'Buat akun'
                    : 'Masuk ke akun',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                'Pencatatan tetap dapat digunakan tanpa akun. Sinkronisasi transaksi bersifat opsional melalui penautan di Pengaturan.',
              ),
              const SizedBox(height: 24),
              if (account.busy) ...[
                const LinearProgressIndicator(semanticsLabel: 'Memproses akun'),
                const SizedBox(height: 16),
              ],
              if (account.message case final message?) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    message,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              if (account.storageProblem) ...[
                OutlinedButton(
                  onPressed: account.busy ? null : account.initialize,
                  child: const Text('Coba lagi'),
                ),
              ] else if (account.hasSession) ...[
                Text(
                  account.user!.email,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  account.verified
                      ? 'Sesi akun aktif.'
                      : 'Sesi tersimpan, belum dapat diperiksa.',
                ),
                const SizedBox(height: 20),
                Text(
                  account.user!.emailVerified
                      ? 'Email terverifikasi.'
                      : 'Email belum terverifikasi.',
                ),
                if (!account.user!.emailVerified)
                  TextButton(
                    onPressed: account.busy
                        ? null
                        : () => Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) => AccountRecoveryScreen(
                                controller: account,
                                verifyEmail: true,
                              ),
                            ),
                          ),
                    child: const Text('Verifikasi email'),
                  ),
                OutlinedButton.icon(
                  onPressed: account.busy ? null : account.refresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Periksa sesi'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: account.canChangePassword ? _changePassword : null,
                  icon: const Icon(Icons.lock_outline),
                  label: const Text('Ganti kata sandi'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: account.canManageSessions
                      ? () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                AccountSessionsScreen(controller: account),
                          ),
                        )
                      : null,
                  icon: const Icon(Icons.devices_outlined),
                  label: const Text('Lihat sesi masuk'),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: account.busy ? null : () => _logout(false),
                  child: const Text('Keluar dari akun'),
                ),
                TextButton(
                  onPressed: account.busy ? null : () => _logout(true),
                  child: const Text('Keluar dari semua perangkat'),
                ),
              ] else if (account.initialized) ...[
                AutofillGroup(
                  child: Form(
                    key: _form,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          controller: _email,
                          enabled: !account.busy,
                          decoration: const InputDecoration(
                            labelText: 'Email',
                            border: OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [
                            AutofillHints.username,
                            AutofillHints.email,
                          ],
                          autocorrect: false,
                          enableSuggestions: false,
                          validator: (value) {
                            final text = (value ?? '').trim();
                            if (text.length > 254 ||
                                !RegExp(
                                  r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                                ).hasMatch(text) ||
                                text.runes.any((rune) => rune > 127)) {
                              return 'Masukkan alamat email yang valid.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _password,
                          enabled: !account.busy,
                          obscureText: !_showPassword,
                          autofillHints: [
                            _register
                                ? AutofillHints.newPassword
                                : AutofillHints.password,
                          ],
                          autocorrect: false,
                          enableSuggestions: false,
                          textInputAction: _register
                              ? TextInputAction.next
                              : TextInputAction.done,
                          onFieldSubmitted: (_) {
                            if (!_register) _submit();
                          },
                          decoration: InputDecoration(
                            labelText: 'Kata sandi',
                            border: const OutlineInputBorder(),
                            helperText: 'Minimal 15 karakter.',
                            suffixIcon: IconButton(
                              onPressed: account.busy
                                  ? null
                                  : () => setState(
                                      () => _showPassword = !_showPassword,
                                    ),
                              tooltip: _showPassword
                                  ? 'Sembunyikan kata sandi'
                                  : 'Tampilkan kata sandi',
                              icon: Icon(
                                _showPassword
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                              ),
                            ),
                          ),
                          validator: (value) {
                            final text = value ?? '';
                            if (text.runes.length < 15) {
                              return 'Gunakan minimal 15 karakter.';
                            }
                            if (utf8.encode(text).length > 128) {
                              return 'Kata sandi terlalu panjang.';
                            }
                            return null;
                          },
                        ),
                        if (_register) ...[
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _confirmation,
                            enabled: !account.busy,
                            obscureText: !_showPassword,
                            decoration: const InputDecoration(
                              labelText: 'Ulangi kata sandi',
                              border: OutlineInputBorder(),
                            ),
                            autofillHints: const [AutofillHints.newPassword],
                            autocorrect: false,
                            enableSuggestions: false,
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) => _submit(),
                            validator: (value) => value != _password.text
                                ? 'Kata sandi belum sama.'
                                : null,
                          ),
                        ],
                        const SizedBox(height: 24),
                        FilledButton(
                          key: const Key('auth_submit'),
                          onPressed: account.canAuthenticate ? _submit : null,
                          child: Text(_register ? 'Daftar' : 'Masuk'),
                        ),
                        if (!_register)
                          TextButton(
                            onPressed: account.busy
                                ? null
                                : () => Navigator.of(context).push<void>(
                                    MaterialPageRoute(
                                      builder: (_) => AccountRecoveryScreen(
                                        controller: account,
                                      ),
                                    ),
                                  ),
                            child: const Text('Lupa kata sandi'),
                          ),
                        TextButton(
                          onPressed: account.busy
                              ? null
                              : () {
                                  _password.clear();
                                  _confirmation.clear();
                                  account.clearMessage();
                                  setState(() {
                                    _register = !_register;
                                    _showPassword = false;
                                  });
                                },
                          child: Text(
                            _register
                                ? 'Sudah punya akun? Masuk'
                                : 'Belum punya akun? Daftar',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}
