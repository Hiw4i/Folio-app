import 'package:flutter/widgets.dart';

import '../widgets/liquid_container.dart';

/// Content-sized panel backed by the shared liquid library. Static: the
/// deforming shell is reserved for interactive controls.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    required this.child,
    this.borderRadius = 24,
    this.padding = EdgeInsets.zero,
    this.fill,
    super.key,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    return LiquidGlass.panel(
      borderRadius: borderRadius,
      padding: padding,
      fill: fill,
      child: child,
    );
  }
}
