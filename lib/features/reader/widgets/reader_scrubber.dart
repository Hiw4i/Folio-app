import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
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

  /// Finger fraction during scrub. A [ValueNotifier] so 120Hz drag updates
  /// repaint only the knob/pill (via [ValueListenableBuilder]) instead of
  /// `setState`-ing the whole strip on every pixel.
  final ValueNotifier<double> _scrubFraction = ValueNotifier<double>(0);

  /// Knob travel (px) from the last layout. Layout cache only: written
  /// during build without `setState`, read by the next drag update so the
  /// knob follows the finger strictly 1:1 with no snap-to-finger teleport.
  double _travelCache = 0;

  /// Frame-coalesced document seek: drag events only store [_pendingSeek],
  /// the actual `jumpTo/goToPosition` runs at most once per frame.
  bool _seekFrameScheduled = false;
  double _pendingSeek = 0;
  bool _hasPendingSeek = false;

  /// Heavy seeks (PDF rasterization, Office platform channel) are additionally
  /// throttled: at most one every [_heavySeekInterval], plus a trailing seek
  /// on release so the document always lands exactly under the finger.
  static const Duration _heavySeekInterval = Duration(milliseconds: 80);
  DateTime _lastHeavySeek = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _heavyTimer;
  double? _trailingHeavySeek;

  /// External progress (scroll fling, page change) coalesced to one rebuild
  /// per frame instead of one `setState` per notify storm tick.
  bool _externalFrameScheduled = false;

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
      _hasPendingSeek = false;
      _seekFrameScheduled = false;
      _trailingHeavySeek = null;
      _heavyTimer?.cancel();
      _heavyTimer = null;
    }
    if (!identical(oldWidget.progressPercent, widget.progressPercent)) {
      oldWidget.progressPercent.removeListener(_handleExternalProgress);
      widget.progressPercent.addListener(_handleExternalProgress);
    }
  }

  @override
  void dispose() {
    _heavyTimer?.cancel();
    _scrubFraction.dispose();
    widget.renderer.removeListener(_handleExternalProgress);
    widget.progressPercent.removeListener(_handleExternalProgress);
    _pdf?.scrollFraction.removeListener(_handleExternalProgress);
    super.dispose();
  }

  /// Follows the document position so the strip stays live. The pill is
  /// shown only while the strip is held, so its `%` / `N / M` text never
  /// duplicates the bottom-left indicator outside scrubbing.
  ///
  /// Coalesced to one rebuild per frame: flings/page-changes can fire
  /// several notifies per frame (renderer + progress + scrollFraction).
  void _handleExternalProgress() {
    if (!mounted || _scrubbing || !_supported) {
      return;
    }
    if (_externalFrameScheduled) {
      return;
    }
    _externalFrameScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _externalFrameScheduled = false;
      if (mounted && !_scrubbing) {
        setState(() {});
      }
    });
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

  bool get _isHeavy => _isPdf || _isWord;

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

  void _scheduleSeek(double fraction) {
    _pendingSeek = fraction.clamp(0.0, 1.0);
    _hasPendingSeek = true;
    if (_seekFrameScheduled) {
      return;
    }
    _seekFrameScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _seekFrameScheduled = false;
      _flushSeek();
    });
  }

  void _flushSeek() {
    if (!_hasPendingSeek || !mounted) {
      return;
    }
    final target = _pendingSeek;
    _hasPendingSeek = false;
    if (_isHeavy) {
      final now = DateTime.now();
      if (now.difference(_lastHeavySeek) < _heavySeekInterval) {
        // Too soon after the previous raster/channel jump: remember the
        // latest finger position and deliver it on the throttle boundary.
        // The knob itself already follows the finger at 120Hz via
        // `_scrubFraction`, so this throttling is invisible.
        _trailingHeavySeek = target;
        _heavyTimer?.cancel();
        final wait =
            _heavySeekInterval - now.difference(_lastHeavySeek);
        _heavyTimer = Timer(wait, () {
          final trailing = _trailingHeavySeek;
          _trailingHeavySeek = null;
          if (trailing == null || !mounted) {
            return;
          }
          _lastHeavySeek = DateTime.now();
          unawaited(_seek(trailing));
        });
        return;
      }
      _lastHeavySeek = now;
    }
    unawaited(_seek(target));
  }

  void _beginScrub(double fraction) {
    if (_scrubbing) {
      return;
    }
    final start = fraction.clamp(0.0, 1.0);
    _scrubFraction.value = start;
    _lastHeavySeek = DateTime.fromMillisecondsSinceEpoch(0);
    _trailingHeavySeek = null;
    _heavyTimer?.cancel();
    _heavyTimer = null;
    setState(() => _scrubbing = true);
    // First jump is immediate so the document starts moving with the finger.
    if (_isHeavy) {
      _lastHeavySeek = DateTime.now();
    }
    unawaited(_seek(start));
  }

  void _updateScrub(double fraction) {
    final target = fraction.clamp(0.0, 1.0);
    // No setState here: only the knob/pill listen to `_scrubFraction`.
    _scrubFraction.value = target;
    _scheduleSeek(target);
  }

  void _endScrub() {
    if (!_scrubbing) {
      return;
    }
    _heavyTimer?.cancel();
    _heavyTimer = null;
    // Exact landing: deliver the very latest finger position synchronously.
    final trailing = _trailingHeavySeek;
    _trailingHeavySeek = null;
    if (_hasPendingSeek || trailing != null) {
      final target = trailing ?? _pendingSeek;
      _hasPendingSeek = false;
      _lastHeavySeek = DateTime.now();
      unawaited(_seek(target));
    }
    setState(() => _scrubbing = false);
  }

  void _dragStart() {
    // Engage at the current position: no teleport, the knob stays exactly
    // where the finger caught it.
    _beginScrub(_scrubbing ? _scrubFraction.value : _liveFraction());
  }

  void _dragUpdate(double dy) {
    if (_travelCache <= 0) {
      return;
    }
    if (!_scrubbing) {
      _dragStart();
    }
    _updateScrub(_scrubFraction.value + dy / _travelCache);
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported || !_isReady() || !_isLongEnough()) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        if (height <= 0 || !height.isFinite) {
          return const SizedBox.shrink();
        }
        final travel = math.max(0.0, height - _edgeInset * 2 - _knobHeight);
        // Layout cache for 1:1 drag math. Not state: no setState, no rebuild.
        _travelCache = travel;
        // Single stable wrapper across grab/release: the ValueListenableBuilder
        // element never remounts, so the knob's GestureDetector keeps tracking
        // the active pointer mid-gesture. Per-pixel motion rebuilds only this
        // small Stack (knob+pill), never the ReaderScreen, and seeks run at
        // most once per frame (heavy seeks throttled to 80ms + trailing).
        // NB: both slots stay keyed so inserting the pill never remounts the
        // knob's GestureDetector mid-gesture (that would drop the tracked
        // pointer and stick `_scrubbing` on).
        return ValueListenableBuilder<double>(
          valueListenable: _scrubFraction,
          builder: (context, scrubFrac, _) {
            final scrubbing = _scrubbing;
            final fraction = scrubbing ? scrubFrac : _liveFraction();
            final label = scrubbing
                ? _scrubLabel(scrubFrac)
                : _liveLabel();
            final clamped = fraction.clamp(0.0, 1.0);
            final knobY = _edgeInset + clamped * travel;
            final pillY = (clamped * (height - _pillHeight))
                .clamp(0.0, math.max(0.0, height - _pillHeight))
                .toDouble();
            final gripHeight = _knobHeight + _grabHalo * 2;
            final gripTop = (knobY - _grabHalo)
                .clamp(0.0, math.max(0.0, height - gripHeight))
                .toDouble();
            return Stack(
              fit: StackFit.expand,
              children: <Widget>[
                // Readout only: appears while the knob is held and deliberately
                // ignores all pointers — pressing it does nothing.
                if (scrubbing)
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
                _knobSlot(
                  gripTop: gripTop,
                  gripHeight: gripHeight,
                  label: label,
                  scrubbing: scrubbing,
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Shared knob slot for both branches: identical 9x36 look, only the
  /// alpha changes (0.65 idle / 1.0 held). Kept as a method so the two
  /// build branches cannot drift visually.
  Widget _knobSlot({
    required double gripTop,
    required double gripHeight,
    required String label,
    required bool scrubbing,
  }) {
    return Positioned(
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
          (scrubbing ? _scrubFraction.value : _liveFraction()) + 0.05,
        ),
        decreasedValue: _scrubLabel(
          (scrubbing ? _scrubFraction.value : _liveFraction()) - 0.05,
        ),
        onIncrease: () => unawaited(
          _seek(
            (scrubbing ? _scrubFraction.value : _liveFraction()) + 0.05,
          ),
        ),
        onDecrease: () => unawaited(
          _seek(
            (scrubbing ? _scrubFraction.value : _liveFraction()) - 0.05,
          ),
        ),
        child: GestureDetector(
          key: const ValueKey<String>('reader_scrub_grip'),
          behavior: HitTestBehavior.translucent,
          onVerticalDragStart: (_) => _dragStart(),
          onVerticalDragUpdate: (details) => _dragUpdate(details.delta.dy),
          onVerticalDragEnd: (_) => _endScrub(),
          onVerticalDragCancel: _endScrub,
          child: RepaintBoundary(
            child: Center(
              child: Container(
                width: _knobWidth,
                height: _knobHeight,
                decoration: BoxDecoration(
                  color: appColors.textPrimary.withValues(
                    alpha: scrubbing ? 1 : 0.65,
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
