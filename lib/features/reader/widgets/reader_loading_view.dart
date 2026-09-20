import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../library/data/document_entry.dart';
import '../../../shared/theme/folio_theme.dart';

/// The single loading surface for every document format.
///
/// The reader chrome (back button, title, search) stays visible above this
/// view; only the content area shows the status: animated dots plus the
/// single line `Opening document`. A short grace period keeps fast documents
/// from flashing a spinner for a single frame: the dots fade in only when
/// loading actually takes noticeable time. Plain-text formats decode
/// especially fast, so their grace is doubled.
class ReaderLoadingView extends StatefulWidget {
  const ReaderLoadingView({
    required this.document,
    this.immediate = false,
    super.key,
  });

  final DocumentEntry document;

  /// Skips the grace period when loading is already known to be slow
  /// (Office staged overlay, PDF byte banner).
  final bool immediate;

  static const Duration grace = AppDurations.grace;
  static const Duration textGrace = AppDurations.slow;
  static const Duration fade = AppDurations.fast;

  static TextStyle titleStyle(BuildContext context) => TextStyle(
        fontFamily: 'Inter',
        color: appColors.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.25,
      );

  @override
  State<ReaderLoadingView> createState() => _ReaderLoadingViewState();
}

class _ReaderLoadingViewState extends State<ReaderLoadingView> {
  bool _visible = false;
  Timer? _graceTimer;

  @override
  void initState() {
    super.initState();
    if (widget.immediate) {
      _visible = true;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_visible || _graceTimer != null) {
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _visible = true;
      return;
    }
    final effectiveGrace = switch (widget.document.format) {
      DocumentFormat.txt ||
      DocumentFormat.markdown => ReaderLoadingView.textGrace,
      DocumentFormat.pdf ||
      DocumentFormat.docx ||
      DocumentFormat.pptx => ReaderLoadingView.grace,
    };
    _graceTimer = Timer(effectiveGrace, () {
      if (mounted) {
        setState(() => _visible = true);
      }
    });
  }

  @override
  void dispose() {
    _graceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedOpacity(
      key: const ValueKey<String>('reader_loading_fade'),
      opacity: _visible ? 1 : 0,
      duration: reducedMotion ? Duration.zero : ReaderLoadingView.fade,
      curve: Curves.easeOutCubic,
      child: IgnorePointer(
        ignoring: !_visible,
        child: ExcludeSemantics(
          excluding: !_visible,
          child: Semantics(
            label: 'Loading document',
            child: Center(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.xxxxl,
                  AppSpacing.xxxxxl + AppSpacing.xl,
                  AppSpacing.xxxxl,
                  AppSpacing.xxxxxl + AppSpacing.xl + AppSpacing.lg,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const ReaderLoadingDots(),
                    SizedBox(height: AppSpacing.lg),
                    Text(
                      'Opening document',
                      textAlign: TextAlign.center,
                      style: ReaderLoadingView.titleStyle(context),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Three-dot wave; static stepped opacities when reduced motion is on.
class ReaderLoadingDots extends StatefulWidget {
  const ReaderLoadingDots({super.key});

  @override
  State<ReaderLoadingDots> createState() => _ReaderLoadingDotsState();
}

class _ReaderLoadingDotsState extends State<ReaderLoadingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return const SizedBox(
        width: 34,
        height: 6,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            _Dot(opacity: 0.35),
            _Dot(opacity: 0.62),
            _Dot(opacity: 0.92),
          ],
        ),
      );
    }
    return Semantics(
      label: 'Loading',
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return SizedBox(
            width: 34,
            height: 6,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                for (var i = 0; i < 3; i++)
                  _Dot(opacity: _dotOpacity(i, _controller.value)),
              ],
            ),
          );
        },
      ),
    );
  }

  double _dotOpacity(int index, double t) {
    final phase = (t + index * 0.2) % 1.0;
    final wave = 0.5 - 0.5 * math.cos(phase * 2 * math.pi);
    return 0.25 + 0.7 * wave;
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.opacity});

  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: appColors.textPrimary.withValues(alpha: opacity),
      ),
    );
  }
}

/// Fades fresh content in once on mount so the loading → content swap never
/// pops. Stateful viewers (PDF controller, Office platform view) must not be
/// wrapped per-branch in ways that remount them; this widget is safe to keep
/// at a stable tree position across loading/ready rebuilds.
class ReaderContentFadeIn extends StatelessWidget {
  const ReaderContentFadeIn({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Opacity(opacity: value, child: child);
      },
      child: child,
    );
  }
}
