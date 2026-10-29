import 'dart:async';

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import '../theme/app_springs.dart';

/// Reveals one group from its centre with a shared scale/opacity spring.
/// Keep this widget mounted while changing [visible] to animate both ways.
/// Hidden content immediately leaves hit testing, focus and semantics.
class ScaleReveal extends StatefulWidget {
  const ScaleReveal({
    required this.visible,
    required this.child,
    this.alignment = Alignment.center,
    this.animateOnMount = false,
    this.onHidden,
    super.key,
  });

  final bool visible;
  final Widget child;
  final Alignment alignment;
  final bool animateOnMount;
  final VoidCallback? onHidden;

  @override
  State<ScaleReveal> createState() => _ScaleRevealState();
}

class _ScaleRevealState extends State<ScaleReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion;
  bool? _reducedMotion;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _motion = AnimationController.unbounded(
      vsync: this,
      value: widget.visible && !widget.animateOnMount ? 1 : 0,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (_reducedMotion != reduced) {
      _reducedMotion = reduced;
      _retarget();
    }
  }

  @override
  void didUpdateWidget(ScaleReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible != oldWidget.visible) _retarget();
  }

  void _retarget() {
    final target = widget.visible ? 1.0 : 0.0;
    final generation = ++_generation;
    if (_reducedMotion ?? false) {
      _motion.value = target;
      if (!widget.visible) _notifyHidden(generation);
      return;
    }
    if (_motion.value == target && !_motion.isAnimating) {
      if (!widget.visible) _notifyHidden(generation);
      return;
    }
    unawaited(
      _motion
          .animateWith(
            SpringSimulation(
              AppSprings.reveal(visible: widget.visible),
              _motion.value,
              target,
              _motion.velocity,
              snapToEnd: true,
              tolerance: const Tolerance(distance: .0001, velocity: .001),
            ),
          )
          .then((_) {
            if (!widget.visible) _notifyHidden(generation);
          }),
    );
  }

  void _notifyHidden(int generation) {
    // A reduced-motion update can arrive during build. Owners may release
    // retained content only after layout, and only for the current exit.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _generation && !widget.visible) {
        widget.onHidden?.call();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _generation++;
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeFocus(
    excluding: !widget.visible,
    child: IgnorePointer(
      ignoring: !widget.visible,
      child: ExcludeSemantics(
        excluding: !widget.visible,
        child: AnimatedBuilder(
          animation: _motion,
          child: widget.child,
          builder: (context, child) => Opacity(
            opacity: _motion.value.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: _motion.value.clamp(0.0, double.infinity),
              alignment: widget.alignment,
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}
