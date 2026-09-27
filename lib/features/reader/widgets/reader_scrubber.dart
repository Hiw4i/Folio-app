import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import '../../../shared/glass/liquid_glass.dart';
import '../../../shared/theme/folio_theme.dart';
import '../logic/document_renderer.dart';
import '../logic/reader_state.dart';

/// Custom fast-scroll strip for md/txt/docx/pdf.
///
/// A small knob on the right edge marks the file position. Only the knob
/// itself is interactive: dragging it scrubs the document super fast
/// (the rest of the edge lets all touches pass through to the document):
/// - md/txt — direct [AutoScrollController.jumpTo], no animation;
/// - pdf — [PdfDocumentRenderer.seekToFraction] straight to the document
///   offset with [Duration.zero];
/// - docx — [OfficeDocumentRendererBase.seekToFraction] page jump.
///
/// The liquid-glass pill with `%` / `N / M` inside (the same 62x38 look as
/// the bottom-left indicator, which stays untouched) is a pure readout: it
/// floats next to the strip only while scrubbing and never handles taps —
/// pressing it does nothing.
///
/// Short files (up to ~2 pages/screens) show nothing at all.
class ReaderScrubber extends StatefulWidget {
  const ReaderScrubber({
    required this.renderer,
    required this.scrollController,
    required this.progressPercent,
    super.key,
  });

  final DocumentRenderer renderer;
  final AutoScrollController scrollController;
  final ValueNotifier<int> progressPercent;

  @override
  State<ReaderScrubber> createState() => _ReaderScrubberState();
}

class _ReaderScrubberState extends State<ReaderScrubber> {
  static const double _pillHeight = 38;
  static const double _stripWidth = 40;
  static const double _edgeInset = 10;
  static const double _knobWidth = 9;
  static const double _knobHeight = 36;

  /// Invisible grab halo around the knob: only this box handles gestures,
  /// everything else on the edge passes touches through to the document.
  static const double _grabHalo = 14;

  bool _scrubbing = false;
  double _scrubFraction = 0;

  /// Knob travel (px) from the last build. Drag updates advance the
  /// fraction by `delta.dy / _dragTravel`, so the knob follows the finger
  /// strictly 1:1 with no snap-to-finger teleport on grab.
  double _dragTravel = 0;

  bool get _isText => widget.renderer is TextDocumentRenderer;
  bool get _isPdf => widget.renderer is PdfDocumentRenderer;
  bool get _isWord => widget.renderer is WordDocumentRenderer;
  bool get _supported => _isText || _isPdf || _isWord;

  PdfDocumentRenderer? get _pdf =>
      widget.renderer is PdfDocumentRenderer
          ? widget.renderer as PdfDocumentRenderer
          : null;

  @override
  void initState() {
    super.initState();
    widget.renderer.addListener(_handleExternalProgress);
    widget.progressPercent.addListener(_handleExternalProgress);
    _pdf?.scrollFraction.addListener(_handleExternalProgress);
  }

  @override
  void didUpdateWidget(ReaderScrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.renderer, widget.renderer)) {
      oldWidget.renderer.removeListener(_handleExternalProgress);
      final oldPdf = oldWidget.renderer is PdfDocumentRenderer
          ? oldWidget.renderer as PdfDocumentRenderer
          : null;
      oldPdf?.scrollFraction.removeListener(_handleExternalProgress);
      widget.renderer.addListener(_handleExternalProgress);
      _pdf?.scrollFraction.addListener(_handleExternalProgress);
      _scrubbing = false;
    }
    if (!identical(oldWidget.progressPercent, widget.progressPercent)) {
      oldWidget.progressPercent.removeListener(_handleExternalProgress);
      widget.progressPercent.addListener(_handleExternalProgress);
    }
  }

  @override
  void dispose() {
    widget.renderer.removeListener(_handleExternalProgress);
    widget.progressPercent.removeListener(_handleExternalProgress);
    _pdf?.scrollFraction.removeListener(_handleExternalProgress);
    super.dispose();
  }

  /// Follows the document position so the strip stays live. The pill is
  /// shown only while the strip is held, so its `%` / `N / M` text never
  /// duplicates the bottom-left indicator outside scrubbing.
  void _handleExternalProgress() {
    if (!mounted || _scrubbing || !_supported) {
      return;
    }
    setState(() {});
  }

  bool _isReady() {
    final renderer = widget.renderer;
    if (renderer is PdfDocumentRenderer) {
      return renderer.loadState == ReaderLoadState.ready ||
          renderer.sourceReady;
    }
    if (renderer is OfficeDocumentRendererBase) {
      return renderer.loadState == ReaderLoadState.ready ||
          renderer.sourceReady;
    }
    if (renderer is TextDocumentRenderer) {
      return renderer.loadState == ReaderLoadState.ready;
    }
    return false;
  }

  /// Short files (up to ~2 pages/screens) get no scrubber at all.
  bool _isLongEnough() {
    final renderer = widget.renderer;
    if (renderer is TextDocumentRenderer) {
      final controller = widget.scrollController;
      if (!controller.hasClients) {
        return false;
      }
      final position = controller.position;
      if (!position.viewportDimension.isFinite ||
          position.viewportDimension <= 0 ||
          !position.maxScrollExtent.isFinite) {
        return false;
      }
      return position.maxScrollExtent > position.viewportDimension;
    }
    if (renderer is PdfDocumentRenderer) {
      return renderer.pageCount > 2;
    }
    if (renderer is OfficeDocumentRendererBase) {
      return renderer.positionCount > 2;
    }
    return false;
  }

  double _liveFraction() {
    final renderer = widget.renderer;
    if (renderer is TextDocumentRenderer) {
      final controller = widget.scrollController;
      if (!controller.hasClients) {
        return 0;
      }
      final position = controller.position;
      final max = position.maxScrollExtent;
      if (max <= 0) {
        return 0;
      }
      return (position.pixels / max).clamp(0.0, 1.0);
    }
    if (renderer is PdfDocumentRenderer) {
      final smooth = renderer.scrollFraction.value;
      if (smooth.isFinite && smooth > 0) {
        return smooth.clamp(0.0, 1.0);
      }
      return renderer.pageFraction;
    }
    if (renderer is OfficeDocumentRendererBase) {
      return renderer.pageFraction;
    }
    return 0;
  }

  /// Same text as the bottom-left progress pill for the live position.
  String _liveLabel() {
    final renderer = widget.renderer;
    if (renderer is TextDocumentRenderer) {
      return '${widget.progressPercent.value}%';
    }
    if (renderer is PdfDocumentRenderer) {
      return renderer.positionLabel;
    }
    if (renderer is OfficeDocumentRendererBase) {
      return renderer.positionLabel;
    }
    return '';
  }

  /// Projected label for the finger position while scrubbing, so feedback
  /// is instant even before the renderer reports the new position.
  String _scrubLabel(double fraction) {
    final renderer = widget.renderer;
    final clamped = fraction.clamp(0.0, 1.0);
    if (renderer is TextDocumentRenderer) {
      return '${(clamped * 100).round()}%';
    }
    if (renderer is PdfDocumentRenderer) {
      if (renderer.pageCount <= 0) {
        return 'PDF';
      }
      final page = (1 + (clamped * (renderer.pageCount - 1)).round()).clamp(
        1,
        renderer.pageCount,
      );
      return '$page / ${renderer.pageCount}';
    }
    if (renderer is OfficeDocumentRendererBase) {
      if (renderer.positionCount <= 0) {
        return renderer.positionLabel;
      }
      final position =
          (1 + (clamped * (renderer.positionCount - 1)).round()).clamp(
            1,
            renderer.positionCount,
          );
      return '$position / ${renderer.positionCount}';
    }
    return '';
  }

  Future<void> _seek(double fraction) async {
    final renderer = widget.renderer;
    final target = fraction.clamp(0.0, 1.0);
    if (renderer is TextDocumentRenderer) {
      final controller = widget.scrollController;
      if (!controller.hasClients) {
        return;
      }
      final position = controller.position;
      controller.jumpTo(
        (target * position.maxScrollExtent)
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble(),
      );
    } else if (renderer is PdfDocumentRenderer) {
      await renderer.seekToFraction(target);
    } else if (renderer is OfficeDocumentRendererBase) {
      await renderer.seekToFraction(target);
    }
  }

  void _beginScrub(double fraction) {
    if (_scrubbing) {
      return;
    }
    setState(() {
      _scrubbing = true;
      _scrubFraction = fraction.clamp(0.0, 1.0);
    });
  }

  void _updateScrub(double fraction) {
    final target = fraction.clamp(0.0, 1.0);
    setState(() => _scrubFraction = target);
    unawaited(_seek(target));
  }

  void _endScrub() {
    if (!_scrubbing) {
      return;
    }
    setState(() => _scrubbing = false);
  }

  void _dragStart() {
    // Engage at the current position: no teleport, the knob stays exactly
    // where the finger caught it.
    _beginScrub(_scrubbing ? _scrubFraction : _liveFraction());
  }

  void _dragUpdate(double dy) {
    if (_dragTravel <= 0) {
      return;
    }
    if (!_scrubbing) {
      _dragStart();
    }
    _updateScrub(_scrubFraction + dy / _dragTravel);
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported || !_isReady() || !_isLongEnough()) {
      return const SizedBox.shrink();
    }
    final fraction = _scrubbing ? _scrubFraction : _liveFraction();
    final label = _scrubbing ? _scrubLabel(_scrubFraction) : _liveLabel();
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        if (height <= 0 || !height.isFinite) {
          return const SizedBox.shrink();
        }
        final travel = math.max(0.0, height - _edgeInset * 2 - _knobHeight);
        final knobY = _edgeInset + fraction.clamp(0.0, 1.0) * travel;
        final pillY = (fraction.clamp(0.0, 1.0) * (height - _pillHeight))
            .clamp(0.0, math.max(0.0, height - _pillHeight))
            .toDouble();
        final gripHeight = _knobHeight + _grabHalo * 2;
        final gripTop = (knobY - _grabHalo)
            .clamp(0.0, math.max(0.0, height - gripHeight))
            .toDouble();
        _dragTravel = travel;
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // Readout only: appears while the knob is held and deliberately
            // ignores all pointers — pressing it does nothing.
            // NB: both slots are keyed so inserting the pill never remounts
            // the knob's GestureDetector mid-gesture (that would drop the
            // tracked pointer and stick `_scrubbing` on).
            if (_scrubbing)
              Positioned(
                key: const ValueKey<String>('reader_scrub_pill_slot'),
                right: _stripWidth + 4,
                top: pillY,
                child: IgnorePointer(
                  child: _ScrubPill(
                    key: const ValueKey<String>('reader_scrub_pill'),
                    label: label,
                  ),
                ),
              ),
            // The ONLY interactive element: the small knob (plus an
            // invisible grab halo). No taps anywhere else, no full-height
            // strip: every other touch passes through to the document.
            Positioned(
              key: const ValueKey<String>('reader_scrub_knob_slot'),
              right: 0,
              top: gripTop,
              width: _stripWidth,
              height: gripHeight,
              child: Semantics(
                slider: true,
                label: 'Document scroll slider',
                value: label,
                increasedValue: _scrubLabel(
                  (_scrubbing ? _scrubFraction : _liveFraction()) + 0.05,
                ),
                decreasedValue: _scrubLabel(
                  (_scrubbing ? _scrubFraction : _liveFraction()) - 0.05,
                ),
                onIncrease: () =>
                    unawaited(_seek((_scrubbing
                            ? _scrubFraction
                            : _liveFraction()) +
                        0.05)),
                onDecrease: () =>
                    unawaited(_seek((_scrubbing
                            ? _scrubFraction
                            : _liveFraction()) -
                        0.05)),
                child: GestureDetector(
                  key: const ValueKey<String>('reader_scrub_grip'),
                  behavior: HitTestBehavior.translucent,
                  onVerticalDragStart: (_) => _dragStart(),
                  onVerticalDragUpdate: (details) =>
                      _dragUpdate(details.delta.dy),
                  onVerticalDragEnd: (_) => _endScrub(),
                  onVerticalDragCancel: _endScrub,
                  child: RepaintBoundary(
                    child: Center(
                      child: Container(
                        width: _knobWidth,
                        height: _knobHeight,
                        decoration: BoxDecoration(
                          color: appColors.textPrimary.withValues(
                            alpha: _scrubbing ? 1 : 0.65,
                          ),
                          borderRadius: BorderRadius.circular(
                            _knobWidth / 2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The same liquid-glass pill look as the bottom-left `_ProgressPill`
/// (62x38, label inside): a pure readout thumb, never interactive.
class _ScrubPill extends StatelessWidget {
  const _ScrubPill({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return LiquidGlassControl(
      size: const Size(_ReaderScrubberSizes.pillWidth, _ReaderScrubberSizes.pillHeight),
      child: Center(
        child: AdaptiveGlassText(
          label,
          style: AppTextStyles.smallDim(context),
        ),
      ),
    );
  }
}

abstract final class _ReaderScrubberSizes {
  static const double pillWidth = 62;
  static const double pillHeight = 38;
}
