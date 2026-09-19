import 'package:flutter/widgets.dart';

import '../widgets/liquid_container.dart';

/// Content-sized panel backed by the shared liquid library.
///
/// Static by default. [liquidMotion] opts into the existing deforming material
/// while keeping inner cards, controls and scrolling stationary.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    required this.child,
    this.borderRadius = 24,
    this.padding = EdgeInsets.zero,
    this.liquidMotion = false,
    this.fill,
    super.key,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final bool liquidMotion;
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    return LiquidGlass.panel(
      liquidMotion: liquidMotion,
      borderRadius: borderRadius,
      padding: padding,
      fill: fill,
      child: child,
    );
  }
}
