import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'backup_codec.dart';

abstract interface class BackupFiles {
  Future<bool> save(Uint8List bytes);
  Future<Uint8List?> read();
}

class NativeBackupFiles implements BackupFiles {
  @override
  Future<bool> save(Uint8List bytes) async =>
      await FilePicker.saveFile(
        fileName:
            'catat-uang-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.cuenc',
        bytes: bytes,
        dialogTitle: 'Simpan backup terenkripsi',
      ) !=
      null;
  @override
  Future<Uint8List?> read() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Pilih backup Catat Uang',
    );
    if (file == null) {
      return null;
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (bytes.length + chunk.length > maxBackupBytes) {
        throw const BackupFailure('File backup melebihi batas 20 MiB.');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }
}
