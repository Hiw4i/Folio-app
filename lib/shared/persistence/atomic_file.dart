import 'dart:io';

/// A caller-derivable staging path for [destinationPath]. Unique per call —
/// the serial disambiguates calls within one clock tick (Windows wall-clock
/// granularity is ~15 ms) — so concurrent writers within an isolate, even to
/// the same destination, never race one temp file. Exported so tests can
/// reason about leftover staging files.
int _stagingSerial = 0;

String temporaryPathFor(String destinationPath) {
  final stamp = DateTime.now().microsecondsSinceEpoch;
  return '$destinationPath.${++_stagingSerial}-$stamp.tmp';
}

/// Replaces a derived local file only after the replacement has been flushed.
///
/// The swap is a single atomic rename wherever the platform supports
/// renaming over an existing file (POSIX — Android included). Windows cannot
/// rename over an existing file, so there the last good file is renamed
/// aside to a backup and moved back if the swap still fails. A crash at any
/// point therefore leaves either the new file or the old file on disk —
/// the old file possibly under the `.bak` name, where [restoreFromBackup]
/// recovers it. Callers serialize writes to a given destination.
Future<void> writeFileAtomically(
  File destination,
  String contents, {
  String? temporaryPath,
}) async {
  await destination.parent.create(recursive: true);
  final temporary = File(temporaryPath ?? temporaryPathFor(destination.path));
  final backup = File('${destination.path}.bak');
  var replaced = false;
  try {
    await temporary.writeAsString(contents, flush: true);
    try {
      await temporary.rename(destination.path);
      replaced = true;
    } on FileSystemException {
      // The platform cannot rename over the existing file (Windows). Move
      // the last good file aside, swap again, and move it back if the swap
      // still fails — the destination must never be destroyed by a failed
      // write.
      if (await _pathType(destination) != FileSystemEntityType.notFound) {
        await _bestEffortDelete(backup);
        await _renameWithRetry(destination, backup.path);
      }
      try {
        await _renameWithRetry(temporary, destination.path);
        replaced = true;
      } on FileSystemException {
        // The swap failed after the backup was made. Move the last good
        // file back before surfacing the error, then rethrow so the caller
        // still knows the write failed.
        if (await _pathType(backup) != FileSystemEntityType.notFound) {
          if (await _pathType(destination) != FileSystemEntityType.notFound) {
            await destination.delete();
          }
          await _renameWithRetry(backup, destination.path);
        }
        rethrow;
      }
    }
  } finally {
    await _bestEffortDelete(temporary);
    if (replaced) {
      await _bestEffortDelete(backup);
    }
    // If !replaced and the backup still exists, the restore above failed.
    // Keeping the backup is deliberate: it is the only surviving copy, and
    // [restoreFromBackup] recovers it on the next read.
  }
}

/// Restores the backup of [destination] after a crash left the destination
/// absent — the window between the backup rename and the swap, or a failed
/// restore. Readers call this before treating a missing file as empty.
/// Returns true when the destination exists afterwards.
Future<bool> restoreFromBackup(File destination) async {
  if (await _pathType(destination) != FileSystemEntityType.notFound) {
    return true;
  }
  final backup = File('${destination.path}.bak');
  if (await _pathType(backup) != FileSystemEntityType.file) {
    return false;
  }
  try {
    await _renameWithRetry(backup, destination.path);
    return true;
  } on FileSystemException {
    return false;
  }
}

/// The path's entity type without following links: `File.exists` reports
/// false for directories, and a link must never be treated as its target.
Future<FileSystemEntityType> _pathType(FileSystemEntity entity) =>
    FileSystemEntity.type(entity.path, followLinks: false);

Future<void> _bestEffortDelete(File file) async {
  try {
    if (await _pathType(file) == FileSystemEntityType.file) {
      await file.delete();
    }
  } on FileSystemException {
    // Cleanup must not mask the original write/rename failure. Leftovers are
    // reclaimed by the next write.
  }
}

const List<Duration> _renameRetryDelays = <Duration>[
  Duration(milliseconds: 25),
  Duration(milliseconds: 50),
  Duration(milliseconds: 100),
];

/// Renames [source] onto [target], retrying briefly on failure.
///
/// Windows keeps a freshly deleted path in a short "delete pending" state
/// during which renames onto it fail with ACCESS_DENIED, and antivirus
/// scanners hold destination files transiently for the same reason. The
/// bounded backoff rides out that window; a permanently invalid target (a
/// directory squatting the name, a read-only parent) still fails fast.
Future<void> _renameWithRetry(File source, String target) async {
  var attempt = 0;
  while (true) {
    try {
      await source.rename(target);
      return;
    } on FileSystemException {
      if (attempt >= _renameRetryDelays.length) {
        rethrow;
      }
      await Future<void>.delayed(_renameRetryDelays[attempt]);
      attempt += 1;
    }
  }
}
