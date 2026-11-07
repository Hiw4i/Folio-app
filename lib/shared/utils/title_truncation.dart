import 'package:flutter/widgets.dart';

import 'text_measurer.dart';

/// Truncates a file name to fit [maxWidth], keeping the extension readable:
/// `(Edited) Моя психика в социальн...pdf`, `Как сделать вку...txt`.
/// Names without a usable extension fall back to a plain end-ellipsis.
///
/// The reader title pill runs inside a LayoutBuilder on every chrome tick and
/// binary-searches the truncation point, so measurements are cached.
final class TitleTruncator {
  TitleTruncator({BoundedTextMeasurer? measurer})
    : _measurer = measurer ?? BoundedTextMeasurer();

  final BoundedTextMeasurer _measurer;

  /// Raw cached width under the same style — used to size the pill around
  /// the (already truncated) label without a second measurement pass.
  double measure(
    String text,
    TextStyle style,
    TextDirection direction,
    TextScaler textScaler,
  ) => _measurer.widthOf(
    text,
    style: style,
    direction: direction,
    textScaler: textScaler,
  );

  String truncate(
    String name,
    TextStyle style,
    double maxWidth,
    TextDirection direction,
    TextScaler textScaler,
  ) {
    double widthOf(String text) => _measurer.widthOf(
      text,
      style: style,
      direction: direction,
      textScaler: textScaler,
    );
    if (widthOf(name) <= maxWidth) {
      return name;
    }
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) {
      return _truncateWithSuffix(name, '…', maxWidth, widthOf);
    }
    final stem = name.substring(0, dot);
    final extension = name.substring(dot + 1);
    final suffix = '...$extension';
    // Callers can scale down the extension if the available width is tiny.
    if (widthOf(suffix) > maxWidth) {
      return extension;
    }
    return _truncateWithSuffix(stem, suffix, maxWidth, widthOf);
  }

  static String _truncateWithSuffix(
    String stem,
    String suffix,
    double maxWidth,
    double Function(String text) widthOf,
  ) {
    final characters = stem.characters;
    String label(int length) => '${characters.take(length)}$suffix';
    var lo = 0;
    var hi = characters.length;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (widthOf(label(mid)) <= maxWidth) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return label(lo);
  }
}
