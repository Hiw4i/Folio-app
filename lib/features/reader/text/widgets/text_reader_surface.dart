import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import '../../../../shared/diagnostics/app_log.dart';
import '../../../../shared/theme/folio_theme.dart';
import '../logic/text_document_renderer.dart';
import '../../widgets/reader_loading_view.dart';
import 'text_document_view.dart';

/// Text surface: the document view plus the reveal lifecycle for the active
/// search hit — the geometry work that needs widget lifecycle and render-tree
/// access, so the reader shell never has to know what a RenderParagraph is.
class TextReaderSurface extends StatefulWidget {
  const TextReaderSurface({
    required this.renderer,
    required this.scrollController,
    this.onSelectionChanged,
    super.key,
  });

  final TextDocumentRenderer renderer;
  final AutoScrollController scrollController;
  final ValueChanged<bool>? onSelectionChanged;

  @override
  State<TextReaderSurface> createState() => _TextReaderSurfaceState();
}

class _TextReaderSurfaceState extends State<TextReaderSurface> {
  GlobalKey _activeHitKey = GlobalKey();
  int _revealGeneration = 0;
  int _lastActiveHit = -2;

  @override
  void initState() {
    super.initState();
    _lastActiveHit = widget.renderer.activeHitIndex;
  }

  @override
  void didUpdateWidget(TextReaderSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.renderer, widget.renderer)) {
      _revealGeneration += 1;
      _lastActiveHit = widget.renderer.activeHitIndex;
      return;
    }
    _revealIfNewHit();
  }

  /// Same trigger the shell used to own: the renderer notified and the
  /// active hit changed.
  void _revealIfNewHit() {
    final hitIndex = widget.renderer.activeHitIndex;
    if (_lastActiveHit == hitIndex) {
      return;
    }
    _lastActiveHit = hitIndex;
    final generation = ++_revealGeneration;
    _activeHitKey = GlobalKey(debugLabel: 'reader active search hit $hitIndex');
    if (widget.renderer.activeHit != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_revealActiveHit(generation));
      });
    }
  }

  Future<void> _revealActiveHit(int generation) async {
    if (!mounted || !widget.scrollController.hasClients) {
      return;
    }
    final renderer = widget.renderer;
    final hit = renderer.activeHit;
    if (hit == null) {
      return;
    }
    final content = renderer.content;
    if (content == null || content.chunks.isEmpty) {
      return;
    }
    final chunkIndex = hit.chunkIndex;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (_activeHitKey.currentContext == null) {
      try {
        await widget.scrollController.scrollToIndex(
          chunkIndex,
          preferPosition: AutoScrollPosition.begin,
          duration: reducedMotion ? Duration.zero : AppDurations.fast,
        );
      } catch (error, stack) {
        // Route disposal can invalidate the target between scheduling and
        // scrolling; debug-only visibility, the failure is expected.
        AppLog.d('Active-hit scroll skipped: $error\n$stack');
        return;
      }
    }
    if (!mounted || generation != _revealGeneration) {
      return;
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _revealGeneration) {
      return;
    }

    final targetContext = _activeHitKey.currentContext;
    final targetObject = targetContext?.findRenderObject();
    if (targetContext == null ||
        !targetContext.mounted ||
        targetObject == null ||
        !targetObject.attached) {
      return;
    }
    final paragraph = content.isMarkdown
        ? null
        : findRenderParagraph(targetObject);
    final revealObject = paragraph ?? targetObject;
    final viewport = RenderAbstractViewport.maybeOf(revealObject);
    if (viewport == null) {
      return;
    }
    if (!widget.scrollController.hasClients) {
      return;
    }
    final position = widget.scrollController.position;
    var targetOffset = viewport.getOffsetToReveal(revealObject, 0.28).offset;
    if (paragraph != null) {
      final chunk = content.chunks[chunkIndex];
      final localStart = (hit.startOffset - chunk.startOffset).clamp(
        0,
        chunk.text.length,
      );
      final localEnd = (hit.endOffset - chunk.startOffset).clamp(
        localStart,
        chunk.text.length,
      );
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: localStart, extentOffset: localEnd),
      );
      if (boxes.isNotEmpty) {
        targetOffset =
            viewport.getOffsetToReveal(paragraph, 0).offset +
            boxes.first.top -
            position.viewportDimension * 0.28;
      }
    }
    targetOffset = targetOffset.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((position.pixels - targetOffset).abs() < 1) {
      return;
    }
    if (reducedMotion) {
      widget.scrollController.jumpTo(targetOffset);
      return;
    }
    try {
      await widget.scrollController.animateTo(
        targetOffset,
        duration: AppDurations.fast,
        curve: AppCurves.emphasized,
      );
    } catch (error, stack) {
      // A newer search result or route disposal can cancel this animation.
      AppLog.d('Active-hit reveal animation skipped: $error\n$stack');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ReaderContentFadeIn(
      child: TextDocumentView(
        renderer: widget.renderer,
        scrollController: widget.scrollController,
        activeHitKey: _activeHitKey,
        onSelectionChanged: widget.onSelectionChanged,
      ),
    );
  }
}

/// Depth-first search for the first [RenderParagraph] under [root]. The text
/// reveal needs the paragraph box to anchor the hit viewport offset.
RenderParagraph? findRenderParagraph(RenderObject root) {
  if (root is RenderParagraph) {
    return root;
  }
  RenderParagraph? result;
  root.visitChildren((child) {
    result ??= findRenderParagraph(child);
  });
  return result;
}
