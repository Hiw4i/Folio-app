import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../persistence/atomic_file.dart';
import 'folio_settings.dart';

abstract interface class FolioSettingsStore {
  Future<FolioSettings> load();
  Future<void> save(FolioSettings settings);
}

class FileFolioSettingsStore implements FolioSettingsStore {
  FileFolioSettingsStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;

  Future<File> _file() async {
    final directory = await _directoryProvider();
    return File(
      '${directory.path}${Platform.pathSeparator}folio_settings.v1.json',
    );
  }

  @override
  Future<FolioSettings> load() async {
    final file = await _file();
    if (!await file.exists()) {
      return const FolioSettings();
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
        throw const FormatException('Unsupported Folio settings file.');
      }
      return FolioSettings.fromJson(decoded);
    } on FormatException {
      // A corrupt settings file must not poison every future start.
      // Quarantine it once (best-effort) and fall back to defaults.
      try {
        await file.delete();
      } on FileSystemException {
        // Keep defaults when the file cannot be removed.
      }
      return const FolioSettings();
    }
  }

  @override
  Future<void> save(FolioSettings settings) async {
    await writeFileAtomically(await _file(), jsonEncode(settings.toJson()));
  }
}
