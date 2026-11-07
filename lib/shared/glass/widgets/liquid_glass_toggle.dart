import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import '../core/glass_tokens.dart';
import '../../theme/folio_theme.dart';
import 'liquid_glass_control.dart';

/// Liquid-glass switch: the KNOB is the liquid element — a small deforming
/// glass circle riding a spring inside a plain, quiet track (no shadow, no
/// blur, no rim — nothing glassy behind the knob). Taps anywhere on the
/// track toggle; presses on the knob deform its own glass.
///
/// The knob runs its own unbounded spring inside a [RepaintBoundary]:
/// toggling repaints only the switch, never the enclosing sheet.
class LiquidGlassToggle extends StatefulWidget {
  const LiquidGlassToggle({
    required this.value,
    required this.onChanged,
    this.semanticsLabel,
    super.key,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  /// Accessibility label; the toggle role and state are set automatically.
  final String? semanticsLabel;

  @override
  State<LiquidGlassToggle> createState() => _LiquidGlassToggleState();
}

class _LiquidGlassToggleState extends State<LiquidGlassToggle>
    with SingleTickerProviderStateMixin {
  static const double _pillWidth = 52;
  static const double _pillHeight = 32;
  static const double _knobSize = 26;
  static const double _knobInset = 3;

  /// Knob travel in logical pixels (the pill inset on both sides).
  static const double _travel = _pillWidth - _knobSize - _knobInset * 2;

  late final AnimationController _knob = AnimationController.unbounded(
    vsync: this,
    value: widget.value ? 1 : 0,
  );

  @override
  void initState() {
    super.initState();
    _knob.addStatusListener(_snapCompleted);
  }

  /// `snapToEnd`-style settle: a spring stopped by tolerance can rest a
  /// fraction of a percent off the target; landing exactly on 0/1 keeps the
  /// resting knob pixel-true.
  void _snapCompleted(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _knob.value = widget.value ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(LiquidGlassToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      _animateTo(widget.value);
    }
  }

  void _animateTo(bool target) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) {
      _knob.stop();
      _knob.value = target ? 1 : 0;
      return;
    }
    // The glass press spring: fast approach with one small overshoot — the
    // knob slaps into its rest on both ends of the travel.
    _knob.animateWith(
      SpringSimulation(
        const MotionTokens.standard().press,
        _knob.value,
        target ? 1 : 0,
        0,
        tolerance: const Tolerance(distance: 0.0005, velocity: 0.005),
      ),
    );
  }

  void _handleTap() {
    if (widget.onChanged == null) {
      return;
    }
    widget.onChanged!(!widget.value);
    // The spring follows the parent-driven [value] via didUpdateWidget.
  }

  @override
  void dispose() {
    _knob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context);
    return Semantics(
      toggled: widget.value,
      label: widget.semanticsLabel,
      button: true,
      onTap: widget.onChanged == null ? null : _handleTap,
      excludeSemantics: true,
      child: RepaintBoundary(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onChanged == null ? null : _handleTap,
          child: SizedBox(
            width: _pillWidth,
            height: _pillHeight,
            child: AnimatedBuilder(
              animation: _knob,
              builder: (context, _) {
                final t = _knob.value.clamp(0.0, 1.0);
                final travel = _travel * t;
                final rtl = direction == TextDirection.rtl;
                return Stack(
                  children: <Widget>[
                    // Plain, quiet track: a translucent wash with a hairline,
                    // no shadow and no glass.
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: context.colors.primary.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(_pillHeight / 2),
                          border: Border.all(
                            color: context.colors.border,
                            width: 0.8,
                          ),
                        ),
                      ),
                    ),
                    // The knob IS the liquid: its own small glass circle with
                    // the shared press physics.
                    Positioned(
                      left: rtl ? null : _knobInset + travel,
                      right: rtl ? _knobInset + travel : null,
                      top: _knobInset,
                      width: _knobSize,
                      height: _knobSize,
                      child: LiquidGlassControl(
                        size: const Size(_knobSize, _knobSize),
                        onTap: widget.onChanged == null ? null : _handleTap,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
