import '../../../../shared/diagnostics/app_log.dart';
import '../../../library/data/document_entry.dart';
import '../../logic/reader_navigation.dart';
import '../../logic/reader_state.dart';
import '../../office/logic/office_document_renderer_base.dart';

/// Office navigation projection. DOCX pages seek; PPTX slides are exposed as
/// a positional model with [ReaderNavigationSnapshot.canSeek] forced off —
/// PPTX has no scrubber by product rule, and this is where that rule lives,
/// decided by the composition root, not by the shared widgets.
final class OfficeReaderNavigation extends ReadingNavigationSource
    implements ReaderNavigation {
  OfficeReaderNavigation(this.renderer, {required this.supportsScrubbing}) {
    renderer.addListener(_refresh);
  }

  final OfficeDocumentRendererBase renderer;

  /// PPTX stays scrub-free; DOCX pages scrub through platform-channel jumps.
  final bool supportsScrubbing;

  /// Same spacing the platform-channel seeks have always been throttled to.
  static const Duration _minimumSeekInterval = Duration(milliseconds: 80);

  @override
  ReaderNavigationSnapshot computeSnapshot() {
    final ready =
        renderer.sourceReady || renderer.loadState == ReaderLoadState.ready;
    final seekable = supportsScrubbing && ready && renderer.positionCount > 2;
    final hasPositions = renderer.positionCount > 0;
    return ReaderNavigationSnapshot(
      canSeek: seekable,
      showScrubber: seekable,
      confirmedFraction: renderer.positionCount > 1
          ? renderer.pageFraction
          : null,
      positionLabel: renderer.positionLabel,
      kind: renderer.document.format == DocumentFormat.pptx
          ? ReaderPositionKind.slides
          : ReaderPositionKind.pages,
      currentPosition: hasPositions ? renderer.currentPosition : null,
      positionCount: hasPositions ? renderer.positionCount : null,
      minimumSeekInterval: _minimumSeekInterval,
    );
  }

  @override
  String labelForFraction(double fraction) {
    final clamped = normalizeScrubFraction(fraction) ?? 0.0;
    if (renderer.positionCount <= 0) {
      return renderer.positionLabel;
    }
    final position = projectedPosition(clamped, renderer.positionCount);
    return '$position / ${renderer.positionCount}';
  }

  @override
  Future<void> seekToFraction(double fraction) {
    final target = normalizeScrubFraction(fraction);
    if (target == null || !snapshot.canSeek) {
      return Future<void>.value();
    }
    return renderer.seekToFraction(target);
  }

  void _refresh() {
    try {
      refresh();
    } catch (error, stack) {
      AppLog.w('Folio Office navigation projection failed', error, stack);
    }
  }

  @override
  void dispose() {
    if (disposed) {
      return;
    }
    renderer.removeListener(_refresh);
    super.dispose();
  }
}
