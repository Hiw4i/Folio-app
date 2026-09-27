import 'dart:io';

/// Replaces a derived local file only after the replacement has been flushed.
/// Callers serialize writes to a given destination. Never delete the last good
/// file as a fallback for a failed rename (disk-full/permission errors included).
Future<void> writeFileAtomically(File destination, String contents) async {
  await destination.parent.create(recursive: true);
  final temporary = File('${destination.path}.tmp');
  try {
    await temporary.writeAsString(contents, flush: true);
    try {
      await temporary.rename(destination.path);
    } on FileSystemException {
      // Windows cannot rename over an existing file. Remove the last good
      // file only after the replacement is fully flushed to the temp file.
      await destination.delete();
      await temporary.rename(destination.path);
    }
  } finally {
    try {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    } on FileSystemException {
      // Best-effort cleanup must not mask the original write/rename failure.
    }
  }
}
