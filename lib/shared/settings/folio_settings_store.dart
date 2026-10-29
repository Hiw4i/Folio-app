import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../diagnostics/app_log.dart';
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
    final entityType = await FileSystemEntity.type(
      file.path,
      followLinks: false,
    );
    if (entityType == FileSystemEntityType.notFound) {
      // A crash between the backup rename and the swap can leave the file
      // absent with its backup intact: recover it before giving up.
      if (!await restoreFromBackup(file)) {
        return const FolioSettings();
      }
    } else if (entityType != FileSystemEntityType.file) {
      // A link or directory squatting the settings path is not recoverable
      // data. File.exists reports false for it, so without this check the
      // path would silently block every future save; clear it and start
      // from defaults. Only the link itself is removed — never its target.
      AppLog.w('Folio settings path is occupied by a $entityType; cleared.');
      await _quarantine(file, entityType);
      return const FolioSettings();
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
        throw const FormatException('Unsupported Folio settings file.');
      }
      return FolioSettings.fromJson(decoded);
    } catch (error, stack) {
      // An unreadable or corrupt settings file must not poison every future
      // start: quarantine it once (best-effort) and fall back to defaults.
      AppLog.w('Folio settings quarantined', error, stack);
      await _quarantine(file, FileSystemEntityType.file);
      return const FolioSettings();
    }
  }

  /// Moves the poisoned file to a `.corrupt` sibling so the contents remain
  /// inspectable; deleting is the fallback when the rename is not possible.
  /// Links are unlinked without touching their target, and a directory
  /// squatting the path is removed outright (File.rename/delete reject
  /// directories on some platforms).
  Future<void> _quarantine(File file, FileSystemEntityType entityType) async {
    if (entityType == FileSystemEntityType.link) {
      try {
        await Link(file.path).delete();
      } on FileSystemException {
        // The path stays blocked; the next start retries the quarantine.
      }
      return;
    }
    if (entityType == FileSystemEntityType.directory) {
      try {
        await Directory(file.path).delete(recursive: true);
      } on FileSystemException {
        // The path stays blocked; the next start retries the quarantine.
      }
      return;
    }
    final quarantine = File('${file.path}.corrupt');
    try {
      await _bestEffortDelete(quarantine);
      await file.rename(quarantine.path);
      return;
    } on FileSystemException {
      // Fall through to deletion.
    }
    await _bestEffortDelete(file);
  }

  @override
  Future<void> save(FolioSettings settings) async {
    await writeFileAtomically(await _file(), jsonEncode(settings.toJson()));
  }
}

Future<void> _bestEffortDelete(File file) async {
  try {
    if (await file.exists()) {
      await file.delete();
    }
  } on FileSystemException {
    // Nothing to fall back to; the next write reclaims the name.
  }
}
