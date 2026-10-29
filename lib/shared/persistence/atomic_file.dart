import 'dart:io';

/// A caller-derivable staging path for [destinationPath]. Unique per call —
/// the serial disambiguates calls within one clock tick (Windows wall-clock
/// granularity is ~15 ms) — so concurrent writers, even to the same
/// destination, never race one temp file. Exported so tests can reason about
/// leftover staging files.
int _stagingSerial = 0;

String temporaryPathFor(String destinationPath) {
  final stamp = DateTime.now().microsecondsSinceEpoch;
  return '$destinationPath.${++_stagingSerial}-$stamp.tmp';
}

/// Replaces a derived local file only after the replacement has been flushed.
///
/// The last good file is never destroyed as a fallback for a failed write:
/// instead of deleting the destination when the platform cannot rename over
/// it (Windows), the old file is renamed aside to a backup and moved back if
/// the swap fails. A crash at any point therefore leaves either the new file
/// or the old file on disk — never nothing. Callers serialize writes to a
/// given destination.
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
    if (await destination.exists()) {
      try {
        await _bestEffortDelete(backup);
        await destination.rename(backup.path);
      } on FileSystemException {
        // The backup itself could not be made: the destination is untouched,
        // so failing here is safe.
        rethrow;
      }
    }
    try {
      await temporary.rename(destination.path);
      replaced = true;
    } on FileSystemException {
      // The swap failed after the backup was made. The destination must not
      // stay absent — move the last good file back before surfacing the
      // error, then rethrow so the caller still knows the write failed.
      if (await backup.exists()) {
        if (await destination.exists()) {
          await destination.delete();
        }
        await backup.rename(destination.path);
      }
      rethrow;
    }
  } finally {
    await _bestEffortDelete(temporary);
    if (replaced) {
      await _bestEffortDelete(backup);
    }
    // If !replaced and the backup still exists, the restore above failed.
    // Keeping the backup is deliberate: it is the only surviving copy, and
    // the next successful write reclaims the name.
  }
}

Future<void> _bestEffortDelete(File file) async {
  try {
    if (await file.exists()) {
      await file.delete();
    }
  } on FileSystemException {
    // Cleanup must not mask the original write/rename failure. Leftovers are
    // reclaimed by the next write.
  }
}
