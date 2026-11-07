import 'package:flutter/foundation.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import '../../../../shared/diagnostics/app_log.dart';
import '../../logic/reader_navigation.dart';
import '../../logic/reader_state.dart';
import '../../text/logic/text_document_renderer.dart';

/// TXT/Markdown navigation projection: the text viewport's own scroll
/// coordinates. The controller and progress notifier live on the UI side,
/// so this adapter sits next to the widgets rather than in the renderer.
final class TextReaderNavigation extends ReadingNavigationSource
    implements ReaderNavigation {
  TextReaderNavigation({
    required this.renderer,
    required this.scrollController,
    required this.progressPercent,
  }) {
    renderer.addListener(_refresh);
    scrollController.addListener(_refresh);
    progressPercent.addListener(_refresh);
  }

  final TextDocumentRenderer renderer;
  final AutoScrollController scrollController;
  final ValueListenable<int> progressPercent;

  @override
  ReaderNavigationSnapshot computeSnapshot() {
    return ReaderNavigationSnapshot(
      canSeek: _isScrollable,
      showScrubber: _isScrollable,
      confirmedFraction: _confirmedFraction(),
      positionLabel: '${progressPercent.value}%',
      kind: ReaderPositionKind.flow,
      minimumSeekInterval: Duration.zero,
    );
  }

  /// Short files (up to ~2 screens) and detached viewports get no scrubber;
  /// without clients no seek command can execute either.
  bool get _isScrollable {
    if (renderer.loadState != ReaderLoadState.ready ||
        !scrollController.hasClients) {
      return false;
    }
    final position = scrollController.position;
    return position.viewportDimension.isFinite &&
        position.viewportDimension > 0 &&
        position.maxScrollExtent.isFinite &&
        position.maxScrollExtent > position.viewportDimension;
  }

  double? _confirmedFraction() {
    if (!scrollController.hasClients) {
      return null;
    }
    final position = scrollController.position;
    final max = position.maxScrollExtent;
    if (!max.isFinite || max <= 0) {
      return null;
    }
    return (position.pixels / max).clamp(0.0, 1.0);
  }

  @override
  String labelForFraction(double fraction) {
    final clamped = normalizeScrubFraction(fraction) ?? 0.0;
    return '${(clamped * 100).round()}%';
  }

  @override
  Future<void> seekToFraction(double fraction) async {
    final target = normalizeScrubFraction(fraction);
    if (target == null || !_isScrollable) {
      return;
    }
    final position = scrollController.position;
    scrollController.jumpTo(
      (target * position.maxScrollExtent)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble(),
    );
  }

  void _refresh() {
    try {
      refresh();
    } catch (error, stack) {
      AppLog.w('Folio text navigation projection failed', error, stack);
    }
  }

  @override
  void dispose() {
    if (disposed) {
      return;
    }
    renderer.removeListener(_refresh);
    scrollController.removeListener(_refresh);
    progressPercent.removeListener(_refresh);
    super.dispose();
  }
}
