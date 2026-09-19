import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../settings/folio_settings_scope.dart';
import '../core/glass_geometry.dart';
import '../motion/glass_motion_controller.dart';
import '../surface/glass_shell.dart';
import '../surface/liquid_surface.dart';

/// Content-sized mode of the existing liquid material, not a new renderer.
///
/// Only the outer shell deforms. The body keeps its layout, hit targets and
/// scroll position; a passive Listener observes touches without competing with
/// the sheet's dismiss gesture or the controls/scrollables inside it.
class LiquidMotionPanel extends StatefulWidget {
  const LiquidMotionPanel({
    required this.child,
    this.borderRadius = 24,
    this.padding = EdgeInsets.zero,
    this.fill,
    super.key,
  }) : assert(borderRadius >= 0);

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final Color? fill;

  @override
  State<LiquidMotionPanel> createState() => _LiquidMotionPanelState();
}

class _LiquidMotionPanelState extends State<LiquidMotionPanel>
    with SingleTickerProviderStateMixin {
  // Optical room only: it must not increase the sheet's layout or hit area.
  static const double _paintPadding = 40;
  static const Offset _paintOffset = Offset(_paintPadding, _paintPadding);

  late final GlassMotionController _motion;
  int? _pointer;
  Offset _pointerSpaceOrigin = Offset.zero;

  @override
  void initState() {
    super.initState();
    _motion = GlassMotionController(vsync: this, morphEnabled: false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = FolioSettingsScope.liquidMotionEnabledOf(context) &&
        !MediaQuery.disableAnimationsOf(context);
    if (!enabled) {
      _pointer = null;
      _motion.cancelPointer();
    }
    // Keep the same material/body mounted when a preference changes. Reduced
    // motion disables this optional deformation altogether, including tickers.
    _motion.setLiquidMotionEnabled(enabled);
  }

  void _pointerDown(PointerDownEvent event) {
    if (!_motion.liquidMotionEnabled ||
        _pointer != null ||
        event.buttons != kPrimaryButton) {
      return;
    }
    _pointer = event.pointer;
    // The route can move underneath the finger during drag-to-dismiss. Use a
    // stable coordinate space for travel/velocity, not that moving local space.
    _pointerSpaceOrigin = event.position - event.localPosition;
    _motion.beginPointer(
      position: event.localPosition,
      timestamp: event.timeStamp,
      target: GlassPointerTarget.main,
    );
  }

  void _pointerMove(PointerMoveEvent event) {
    if (_pointer != event.pointer) return;
    _motion.movePointer(
      position: event.position - _pointerSpaceOrigin,
      timestamp: event.timeStamp,
    );
    // Reflection follows the actual finger position on the moving material.
    _motion.updateHover(event.localPosition);
  }

  void _pointerUp(PointerUpEvent event) {
    if (_pointer != event.pointer) return;
    _motion.endPointer(
      position: event.position - _pointerSpaceOrigin,
      timestamp: event.timeStamp,
    );
    _motion.updateHover(event.localPosition);
    _pointer = null;
  }

  void _pointerCancel(PointerCancelEvent event) {
    if (_pointer != event.pointer) return;
    _motion.cancelPointer();
    _pointer = null;
  }

  @override
  void dispose() {
    // A captured pointer can finish after the route has removed its surface.
    _pointer = null;
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final opacity = LiquidBlurScope.maybeOpacityOf(context) ?? 1.0;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _pointerDown,
      onPointerMove: _pointerMove,
      onPointerUp: _pointerUp,
      onPointerCancel: _pointerCancel,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            left: -_paintPadding,
            top: -_paintPadding,
            right: -_paintPadding,
            bottom: -_paintPadding,
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final rect = Rect.fromLTWH(
                    _paintPadding,
                    _paintPadding,
                    constraints.maxWidth - _paintPadding * 2,
                    constraints.maxHeight - _paintPadding * 2,
                  );
                  // Only material paint rebuilds at simulation frequency.
                  // Measuring happens in layout, without post-frame setState
                  // or fixing the body to the viewport's maximum height.
                  return AnimatedBuilder(
                    animation: _motion,
                    builder: (context, _) {
                      final light = _motion.lightPosition == Offset.zero
                          ? rect.center
                          : _motion.lightPosition + _paintOffset;
                      return GlassShell(
                        path: GlassGeometryFrame.deformedRoundedRect(
                          rect: rect,
                          radius: widget.borderRadius,
                          origin: light,
                          pull: _motion.displacement,
                          velocity: _motion.pointerVelocity,
                          press: _motion.press,
                        ),
                        glowCenter: light,
                        press: _motion.press,
                        focused: false,
                        blurSigma: _motion.backdropBlurSigma,
                        fill: widget.fill,
                      );
                    },
                  );
                },
              ),
            ),
          ),
          // This non-positioned child determines the panel's natural size.
          // Never put the whole Stack in Opacity: that isolates the backdrop.
          ClipRRect(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            child: Opacity(
              opacity: opacity,
              child: RepaintBoundary(
                child: Padding(padding: widget.padding, child: widget.child),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
