import '../../../../shared/diagnostics/app_log.dart';
import '../../logic/reader_navigation.dart';
import '../../logic/reader_state.dart';
import '../../pdf/logic/pdf_document_renderer.dart';

/// PDF navigation projection: continuous viewer fraction when the viewer
/// matrix is live, page-based fallback before it, page count visibility.
final class PdfReaderNavigation extends ReadingNavigationSource
    implements ReaderNavigation {
  PdfReaderNavigation(this.renderer) {
    renderer.addListener(_refresh);
    renderer.scrollFraction.addListener(_refresh);
  }

  final PdfDocumentRenderer renderer;

  /// Same spacing the heavy seek paths have always used; the scrub
  /// controller schedules with it once it owns dispatching.
  static const Duration _minimumSeekInterval = Duration(milliseconds: 80);

  @override
  ReaderNavigationSnapshot computeSnapshot() {
    final ready =
        renderer.sourceReady || renderer.loadState == ReaderLoadState.ready;
    final hasPages = renderer.pageCount > 0;
    return ReaderNavigationSnapshot(
      canSeek: ready,
      showScrubber: ready && renderer.pageCount > 2,
      confirmedFraction: !hasPages ? null : _confirmedFraction(),
      positionLabel: renderer.positionLabel,
      kind: ReaderPositionKind.pages,
      currentPosition: hasPages ? renderer.currentPage : null,
      positionCount: hasPages ? renderer.pageCount : null,
      minimumSeekInterval: _minimumSeekInterval,
    );
  }

  double _confirmedFraction() {
    final smooth = renderer.scrollFraction.value;
    if (smooth.isFinite && smooth > 0) {
      return smooth.clamp(0.0, 1.0);
    }
    return renderer.pageFraction;
  }

  @override
  String labelForFraction(double fraction) {
    final clamped = normalizeScrubFraction(fraction) ?? 0.0;
    if (renderer.pageCount <= 0) {
      return renderer.positionLabel;
    }
    final page = projectedPosition(clamped, renderer.pageCount);
    return '$page / ${renderer.pageCount}';
  }

  @override
  Future<void> seekToFraction(double fraction) {
    final target = normalizeScrubFraction(fraction);
    if (target == null) {
      return Future<void>.value();
    }
    return renderer.seekToFraction(target);
  }

  void _refresh() {
    try {
      refresh();
    } catch (error, stack) {
      AppLog.w('Folio PDF navigation projection failed', error, stack);
    }
  }

  @override
  void dispose() {
    if (disposed) {
      return;
    }
    renderer.removeListener(_refresh);
    renderer.scrollFraction.removeListener(_refresh);
    super.dispose();
  }
}
