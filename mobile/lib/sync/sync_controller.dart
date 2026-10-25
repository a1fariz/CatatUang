import 'package:flutter/foundation.dart';

import '../auth/account_controller.dart';
import '../auth/auth_models.dart';
import '../transaction_repository.dart';
import 'sync_api.dart';
import 'sync_models.dart';

class TransactionSyncController extends ChangeNotifier {
  TransactionSyncController({
    required this.repository,
    required this.account,
    required TransactionSyncGateway gateway,
  }) : _gateway = gateway;
  final TransactionRepository repository;
  final AccountController account;
  final TransactionSyncGateway _gateway;
  SyncBinding? binding;
  List<SyncIssue> issues = [];
  int pending = 0;
  int dataRevision = 0;
  bool busy = false;
  bool _disposed = false;
  String? message;
  bool get ownerMatches =>
      binding == null ||
      binding!.userId == account.user?.id &&
          binding!.server == account.serverUri.toString();
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> reload() async {
    try {
      binding = await repository.syncBinding();
      pending = await repository.syncPendingCount();
      issues = await repository.syncIssues();
    } catch (_) {
      message = 'Status sinkronisasi gagal dibaca. Coba lagi.';
    }
    _notify();
  }

  Future<void> link({String? expectedUserId}) async {
    if (busy || _disposed) return;
    final expected = expectedUserId ?? account.user?.id;
    busy = true;
    message = null;
    _notify();
    try {
      await account.refresh();
      final user = account.user;
      if (_disposed) return;
      if (user == null || !account.verified || account.busy) {
        throw const SyncFailure('Masuk dan periksa akun terlebih dahulu.');
      }
      if (user.id != expected) {
        throw const SyncFailure(
          'Akun berubah. Periksa akun sebelum menautkan catatan.',
        );
      }
      if (_gateway.baseUri != account.serverUri) {
        throw const SyncFailure('Konfigurasi server berbeda.');
      }
      await repository.linkSync(
        server: account.serverUri,
        userId: user.id,
        email: user.email,
      );
      message =
          'Catatan ditautkan. Tekan Sinkronkan sekarang untuk mengirim dan mengambil transaksi.';
    } on SyncFailure catch (e) {
      message = e.message;
    } catch (_) {
      message = 'Catatan belum dapat ditautkan. Coba lagi.';
    } finally {
      busy = false;
      await reload();
    }
  }

  Future<T> _request<T>(
    SyncBinding ledger,
    Future<T> Function(String) action,
  ) async {
    if (_disposed ||
        (await repository.syncBinding())?.generation != ledger.generation ||
        _gateway.baseUri.toString() != ledger.server) {
      throw const SyncFailure(
        'Penautan catatan sudah berubah. Sinkronisasi dihentikan.',
      );
    }
    return account.authorized(
      userId: ledger.userId,
      server: Uri.parse(ledger.server),
      action: action,
    );
  }

  Future<void> _push(SyncBinding ledger, SyncOperation operation) async {
    try {
      final record = await _request(
        ledger,
        (token) => _gateway.push(token, operation, dataset: ledger.datasetId),
      );
      await repository.acknowledgeSync(ledger.generation, operation, record);
    } on SyncFailure catch (failure) {
      if (failure.code == 'sync_reset_required') rethrow;
      if (failure.status == 409) {
        try {
          final record = await _request(
            ledger,
            (token) => _gateway.snapshot(
              token,
              operation.remoteId,
              dataset: ledger.datasetId,
            ),
          );
          await repository.rejectSync(
            ledger.generation,
            operation,
            server: record,
          );
        } on SyncFailure catch (snapshotFailure) {
          if (snapshotFailure.status != 404) rethrow;
          await repository.rejectSync(
            ledger.generation,
            operation,
            error:
                'ID catatan ditolak dan snapshot akun tidak tersedia. Catatan lokal tetap tersimpan.',
          );
        }
      } else if (failure.status == 422 ||
          failure.status == 400 ||
          failure.status == 413) {
        await repository.rejectSync(
          ledger.generation,
          operation,
          error: failure.message,
        );
      } else {
        rethrow;
      }
    }
  }

  Future<bool> _pull(SyncBinding ledger) async {
    for (var i = 0; i < 50; i++) {
      final current = await repository.syncBinding();
      if (current?.generation != ledger.generation) {
        throw const SyncFailure('Penautan catatan sudah berubah.');
      }
      final page = await _request(
        ledger,
        (token) =>
            _gateway.pull(token, current!.cursor, dataset: ledger.datasetId),
      );
      if (!await repository.applySyncPage(
        ledger.generation,
        current!.cursor,
        page,
      )) {
        throw const SyncFailure('Penautan catatan sudah berubah.');
      }
      if (page.items.isNotEmpty) {
        dataRevision++;
        _notify();
      }
      if (!page.hasMore) return true;
    }
    return false;
  }

  Future<void> synchronize() async {
    if (busy || _disposed) return;
    busy = true;
    message = null;
    _notify();
    try {
      var ledger = await repository.syncBinding();
      if (ledger == null) {
        throw const SyncFailure('Tautkan catatan terlebih dahulu.');
      }
      await account.refresh();
      final target = ledger;
      final dataset = await _request(
        target,
        (token) => _gateway.datasetId(token),
      );
      await repository.pinSyncDataset(target.generation, dataset);
      ledger = await repository.syncBinding();
      if (ledger == null || ledger.generation != target.generation) {
        throw const SyncFailure('Penautan catatan sudah berubah.');
      }
      // Resolve uncertain POST outcomes before pulling their own feed echoes.
      if (account.user?.id != ledger.userId ||
          account.serverUri.toString() != ledger.server ||
          !account.verified ||
          account.busy) {
        throw const SyncFailure(
          'Masuk dan periksa akun pemilik catatan sebelum sinkronisasi.',
        );
      }
      var sent = 0;
      while (sent < 100) {
        final operation = await repository.nextSyncOperation(
          ledger.generation,
          inflightOnly: true,
        );
        if (operation == null) break;
        await _push(ledger, operation);
        sent++;
      }
      if (sent == 100) {
        throw const SyncFailure(
          'Sebagian antrean diproses. Tekan sinkronkan lagi untuk melanjutkan.',
        );
      }
      if (!await _pull(ledger)) {
        throw const SyncFailure(
          'Sebagian data akun diambil. Tekan sinkronkan lagi untuk melanjutkan.',
        );
      }
      while (sent < 100) {
        final operation = await repository.nextSyncOperation(ledger.generation);
        if (operation == null) break;
        await _push(ledger, operation);
        sent++;
      }
      final complete = await _pull(ledger);
      await reload();
      if (issues.isNotEmpty) {
        message =
            'Ada catatan yang perlu diperiksa. Selesaikan konflik atau perbaiki catatan yang ditolak.';
      } else if (pending > 0 || !complete) {
        message =
            'Sebagian perubahan diproses. Tekan sinkronkan lagi untuk melanjutkan.';
      } else {
        await repository.finishSync(ledger.generation);
        message =
            'Transaksi sudah disinkronkan. Tagihan dan pembayaran tetap lokal.';
      }
    } on SyncFailure catch (e) {
      message = e.message;
    } on AuthFailure catch (e) {
      message = e.message;
    } catch (_) {
      message =
          'Sinkronisasi belum selesai. Perubahan lokal tetap tersimpan; coba lagi.';
    } finally {
      busy = false;
      await reload();
    }
  }

  Future<void> resolve(String remoteId, {required bool keepLocal}) async {
    if (busy || _disposed || !ownerMatches || account.user == null) return;
    busy = true;
    message = null;
    _notify();
    try {
      final ledger = await repository.syncBinding();
      if (ledger == null) return;
      await repository.resolveSync(
        ledger.generation,
        remoteId,
        keepLocal: keepLocal,
      );
      dataRevision++;
      message = keepLocal
          ? 'Pilihan perangkat masuk antrean. Sinkronkan lagi untuk mengirimnya.'
          : 'Catatan perangkat diperbarui dari akun.';
    } on SyncFailure catch (e) {
      message = e.message;
    } catch (_) {
      message = 'Konflik belum dapat diselesaikan. Coba lagi.';
    } finally {
      busy = false;
      await reload();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _gateway.close();
    super.dispose();
  }
}
