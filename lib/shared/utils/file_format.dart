/// Shared human-readable formatting for document metadata.
///
/// Single source of truth for file sizes and dates shown in the library
/// list and in the file-info sheet. Previously duplicated in both places
/// with slightly different edge-case behaviour (no GB, negative input).
String formatFileSize(int bytes) {
  final safeBytes = bytes < 0 ? 0 : bytes;
  if (safeBytes < 1024) {
    return '$safeBytes B';
  }
  if (safeBytes < 1024 * 1024) {
    return '${(safeBytes / 1024).toStringAsFixed(safeBytes < 10240 ? 1 : 0)} KB';
  }
  if (safeBytes < 1024 * 1024 * 1024) {
    return '${(safeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(safeBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// Short date for the file-info sheet, e.g. `Sep 12, 2026`.
String formatDocumentDate(DateTime date) {
  const months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = date.toLocal();
  return '${months[local.month - 1]} ${local.day}, ${local.year}';
}
