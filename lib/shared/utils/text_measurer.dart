import 'package:flutter/painting.dart';

/// Caches text widths for hot layout paths that binary-search a truncation
/// point or size chrome around labels on every animation tick. Uncached,
/// each measurement allocates and lays out a [TextPainter]; the working set
/// of labels is small and closed, so a bounded cache with wholesale eviction
/// keeps the hot path allocation-free.
class BoundedTextMeasurer {
  BoundedTextMeasurer({this.capacity = 256}) : assert(capacity > 0);

  final int capacity;
  final Map<String, double> _widths = <String, double>{};

  /// Number of cached measurements; exposed for tests.
  int get size => _widths.length;

  double widthOf(
    String text, {
    required TextStyle style,
    required TextDirection direction,
    required TextScaler textScaler,
  }) {
    final scale = textScaler.scale(style.fontSize ?? 14);
    final key = '$text|${direction.index}|${style.hashCode}|$scale';
    final cached = _widths[key];
    if (cached != null) {
      return cached;
    }
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: direction,
      textScaler: textScaler,
    )..layout();
    final width = painter.width;
    painter.dispose();
    if (_widths.length >= capacity) {
      _widths.clear();
    }
    _widths[key] = width;
    return width;
  }
}
