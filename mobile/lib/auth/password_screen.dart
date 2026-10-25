import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'account_controller.dart';

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key, required this.controller});
  final AccountController controller;
  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _replacement = TextEditingController();
  final _confirmation = TextEditingController();
  bool _visible = false;
  String? _validate(String? value) {
    final text = value ?? '';
    if (text.runes.length < 15) return 'Gunakan minimal 15 karakter.';
    if (utf8.encode(text).length > 128) return 'Kata sandi terlalu panjang.';
    return null;
  }

  Future<void> _submit() async {
    if (!widget.controller.canChangePassword ||
        !_form.currentState!.validate()) {
      return;
    }
    FocusScope.of(context).unfocus();
    final changed = await widget.controller.changePassword(
      _current.text,
      _replacement.text,
    );
    if (!mounted) return;
    // Clear credentials after every attempt, including uncertain network outcomes.
    _current.clear();
    _replacement.clear();
    _confirmation.clear();
    TextInput.finishAutofillContext(shouldSave: changed);
    if (changed) Navigator.pop(context, true);
  }

  @override
  void dispose() {
    _current.dispose();
    _replacement.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final account = widget.controller;
      return PopScope(
        canPop: !account.busy,
        child: Scaffold(
          appBar: AppBar(title: const Text('Ganti kata sandi')),
          body: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                'Kata sandi lama diperlukan. Sesi perangkat lain akan dicabut; sesi ini tetap aktif sampai masa berlakunya berakhir. Catatan lokal tidak dihapus.',
              ),
              const SizedBox(height: 16),
              if (account.busy)
                const LinearProgressIndicator(
                  semanticsLabel: 'Mengganti kata sandi',
                ),
              if (!account.hasSession)
                const Text(
                  'Sesi berakhir. Kembali ke halaman Akun untuk masuk kembali.',
                ),
              if (account.message != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      account.message!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
              AutofillGroup(
                child: Form(
                  key: _form,
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _current,
                        enabled: !account.busy && account.hasSession,
                        obscureText: !_visible,
                        autofillHints: const [AutofillHints.password],
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Kata sandi lama',
                          border: OutlineInputBorder(),
                        ),
                        validator: _validate,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _replacement,
                        enabled: !account.busy && account.hasSession,
                        obscureText: !_visible,
                        autofillHints: const [AutofillHints.newPassword],
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Kata sandi baru',
                          helperText:
                              'Minimal 15 karakter, berbeda dari kata sandi lama.',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) =>
                            _validate(value) ??
                            (value == _current.text
                                ? 'Gunakan kata sandi yang berbeda.'
                                : null),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _confirmation,
                        enabled: !account.busy && account.hasSession,
                        obscureText: !_visible,
                        autofillHints: const [AutofillHints.newPassword],
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _submit(),
                        decoration: const InputDecoration(
                          labelText: 'Ulangi kata sandi baru',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) => value != _replacement.text
                            ? 'Kata sandi belum sama.'
                            : null,
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Tampilkan kata sandi'),
                        value: _visible,
                        onChanged: account.busy
                            ? null
                            : (value) => setState(() => _visible = value),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: account.canChangePassword ? _submit : null,
                        child: const Text('Simpan kata sandi baru'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
