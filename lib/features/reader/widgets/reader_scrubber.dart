import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../../shared/glass/liquid_glass.dart';
import '../../../shared/theme/folio_theme.dart';
import '../logic/reader_navigation.dart';
import '../logic/reader_scrub_controller.dart';

/// Custom fast-scroll strip for md/txt/docx/pdf.
///
/// A small knob on the right edge marks the file position. Only the knob
/// itself is interactive: dragging it scrubs the document super fast
/// (the rest of the edge lets all touches pass through to the document).
/// The format is unknown here: everything — visibility, live position,
/// labels and seek dispatching — comes from the [ReaderNavigation] contract
/// and its [ReaderScrubController] gesture state.
///
/// The liquid-glass pill with `%` / `N / M` inside (the same 62x38 look as
/// the bottom-left indicator, which stays untouched) is a pure readout: it
/// floats next to the strip only while scrubbing and never handles taps —
/// pressing it does nothing.
///
/// Short files (up to ~2 pages/screens) show nothing at all.
class ReaderScrubber extends StatefulWidget {
  const ReaderScrubber({required this.navigation, super.key});

  final ReaderNavigation navigation;

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

  late ReaderScrubController _controller;
  ReaderNavigation? _listenedNavigation;

  /// Knob travel (px) from the last layout. Layout cache only: written
  /// during build without `setState`, read by the next drag update so the
  /// knob follows the finger strictly 1:1 with no snap-to-finger teleport.
  double _travelCache = 0;

  /// External progress (scroll fling, page change) coalesced to one rebuild
  /// per frame instead of one `setState` per notify storm tick.
  bool _externalFrameScheduled = false;

  @override
  void initState() {
    super.initState();
    _attach(widget.navigation);
  }

  @override
  void didUpdateWidget(ReaderScrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.navigation, widget.navigation)) {
      _attach(widget.navigation);
    }
  }

  void _attach(ReaderNavigation navigation) {
    final previous = _listenedNavigation;
    if (previous != null) {
      previous.removeListener(_handleExternalProgress);
      _controller
        ..removeListener(_handleScrubStateChanged)
        ..dispose();
    }
    _listenedNavigation = navigation;
    _controller =
        ReaderScrubController(navigation)..addListener(_handleScrubStateChanged);
    navigation.addListener(_handleExternalProgress);
  }

  @override
  void dispose() {
    _listenedNavigation?.removeListener(_handleExternalProgress);
    _controller
      ..removeListener(_handleScrubStateChanged)
      ..dispose();
    super.dispose();
  }

  /// Follows the document position so the strip stays live. The pill is
  /// shown only while the strip is held, so its `%` / `N / M` text never
  /// duplicates the bottom-left indicator outside scrubbing.
  ///
  /// Coalesced to one rebuild per frame: flings/page-changes can fire
  /// several notifies per frame.
  void _handleExternalProgress() {
    if (!mounted || _controller.isScrubbing) {
      return;
    }
    if (_externalFrameScheduled) {
      return;
    }
    _externalFrameScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _externalFrameScheduled = false;
      if (mounted && !_controller.isScrubbing) {
        setState(() {});
      }
    });
  }

  void _handleScrubStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  double get _liveFraction => widget.navigation.snapshot.confirmedFraction ?? 0;

  void _dragStart() {
    // Engage at the current position: no teleport, the knob stays exactly
    // where the finger caught it.
    _controller.begin(
      _controller.isScrubbing ? _controller.preview.value : _liveFraction,
    );
  }

  void _dragUpdate(double dy) {
    if (_travelCache <= 0) {
      return;
    }
    if (!_controller.isScrubbing) {
      _dragStart();
    }
    _controller.update(_controller.preview.value + dy / _travelCache);
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.navigation.snapshot;
    if (!snapshot.showScrubber) {
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
        // small Stack (knob+pill), never the ReaderScreen, and seeks are
        // dispatched by the scrub controller (once per frame, spaced for
        // heavy formats, exact landing on release).
        // NB: both slots stay keyed so inserting the pill never remounts the
        // knob's GestureDetector mid-gesture (that would drop the tracked
        // pointer and stick the scrub state on).
        return ValueListenableBuilder<double>(
          valueListenable: _controller.preview,
          builder: (context, previewFraction, _) {
            final scrubbing = _controller.isScrubbing;
            final fraction = scrubbing ? previewFraction : _liveFraction;
            final label = scrubbing
                ? widget.navigation.labelForFraction(previewFraction)
                : snapshot.positionLabel;
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
    final basis = scrubbing ? _controller.preview.value : _liveFraction;
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
        increasedValue: widget.navigation.labelForFraction(basis + 0.05),
        decreasedValue: widget.navigation.labelForFraction(basis - 0.05),
        onIncrease: () => unawaited(
          widget.navigation.seekToFraction(basis + 0.05),
        ),
        onDecrease: () => unawaited(
          widget.navigation.seekToFraction(basis - 0.05),
        ),
        child: GestureDetector(
          key: const ValueKey<String>('reader_scrub_grip'),
          behavior: HitTestBehavior.translucent,
          onVerticalDragStart: (_) => _dragStart(),
          onVerticalDragUpdate: (details) => _dragUpdate(details.delta.dy),
          onVerticalDragEnd: (_) => _controller.end(),
          onVerticalDragCancel: _controller.cancel,
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
