import 'package:flutter/foundation.dart';

/// Positional model a format uses. `flow` (TXT/Markdown) scrolls in document
/// coordinates, `pages` (PDF/DOCX) in discrete pages, `slides` (PPTX) in
/// slides with no scrubbing at all.
enum ReaderPositionKind { flow, pages, slides }

/// Immutable navigation state of the active reader.
///
/// [confirmedFraction] is the position the engine has actually confirmed —
/// `null` means "not measured yet", not "top of document". [canSeek] is the
/// command readiness; [showScrubber] the product visibility. Both are kept
/// separate because a surface can be seekable while the scrubber is hidden
/// (short documents) and vice versa.
@immutable
class ReaderNavigationSnapshot {
  const ReaderNavigationSnapshot({
    required this.canSeek,
    required this.showScrubber,
    required this.positionLabel,
    this.confirmedFraction,
    this.kind,
    this.currentPosition,
    this.positionCount,
    this.minimumSeekInterval = Duration.zero,
  });

  final bool canSeek;
  final bool showScrubber;

  /// Position in `[0, 1]` confirmed by the engine, or `null` before the
  /// first measurement.
  final double? confirmedFraction;

  /// Single label source for the persistent indicator and the scrubber pill.
  final String positionLabel;

  /// Positional model of the format, or `null` when none is available.
  final ReaderPositionKind? kind;

  /// 1-based discrete position, `null` for flow documents.
  final int? currentPosition;

  /// 1-based discrete position count, `null` for flow documents.
  final int? positionCount;

  /// Minimum spacing between dispatched seek commands for this format
  /// (`Duration.zero` for cheap text jumps, 80 ms for raster/channel seeks).
  final Duration minimumSeekInterval;

  @override
  bool operator ==(Object other) {
    return other is ReaderNavigationSnapshot &&
        other.canSeek == canSeek &&
        other.showScrubber == showScrubber &&
        other.confirmedFraction == confirmedFraction &&
        other.positionLabel == positionLabel &&
        other.kind == kind &&
        other.currentPosition == currentPosition &&
        other.positionCount == positionCount &&
        other.minimumSeekInterval == minimumSeekInterval;
  }

  @override
  int get hashCode => Object.hash(
    canSeek,
    showScrubber,
    confirmedFraction,
    positionLabel,
    kind,
    currentPosition,
    positionCount,
    minimumSeekInterval,
  );
}

/// Normalizes an incoming scrub fraction: non-finite input is rejected
/// (`null`), finite input is clamped to `[0, 1]`.
double? normalizeScrubFraction(double fraction) {
  return fraction.isFinite ? fraction.clamp(0.0, 1.0) : null;
}

/// Format-agnostic navigation face the shell consumes. Implementations live
/// next to the UI (`widgets/bindings/`) because they may read viewport state;
/// they never own the renderer.
abstract interface class ReaderNavigation implements Listenable {
  ReaderNavigationSnapshot get snapshot;

  /// Format label for a *preview* position — what the pill shows while the
  /// finger is down, before the engine confirms anything.
  String labelForFraction(double fraction);

  /// Queues a seek request. The returned future completing does NOT mean the
  /// frame is on screen; confirmation arrives through [snapshot].
  Future<void> seekToFraction(double fraction);

  /// Recomputes the snapshot from sources for lifecycle moments that produce
  /// no source notification (a viewport attaching to its controller).
  void revalidate();

  /// Removes the adapter's own subscriptions. Never closes the renderer.
  void dispose();
}

/// Shared change detection for navigation adapters: source notifications only
/// reach listeners when the resulting snapshot actually changed, and
/// [snapshot] returns a cached instance between changes. Adapters early-return
/// from their [dispose] override once [disposed] is set, so a double dispose
/// is a no-op instead of a ChangeNotifier assertion.
abstract base class ReadingNavigationSource with ChangeNotifier {
  ReaderNavigationSnapshot? _current;
  bool _disposed = false;

  @protected
  bool get disposed => _disposed;

  ReaderNavigationSnapshot get snapshot => _current ??= computeSnapshot();

  /// Recompute from sources; notify listeners only on a real change.
  @protected
  void refresh() {
    final next = computeSnapshot();
    if (next != _current) {
      _current = next;
      notifyListeners();
    }
  }

  /// Public revalidation for lifecycle moments that produce no source
  /// notification — a viewport attaching to its scroll controller changes
  /// seekability without any listener callback firing.
  void revalidate() => refresh();

  @protected
  ReaderNavigationSnapshot computeSnapshot();

  @override
  @mustCallSuper
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Projects a discrete position fraction the same way every scrub label
/// does: `1 + round(fraction * (count - 1))`, clamped into `[1, count]`.
int projectedPosition(double fraction, int count) {
  return (1 + (fraction * (count - 1)).round()).clamp(1, count);
}
