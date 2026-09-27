import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../settings/folio_settings_scope.dart';

import '../core/glass_geometry.dart';
import '../core/liquid_shape.dart';
import '../motion/glass_motion_controller.dart';
import '../surface/glass_shell.dart';
import '../surface/liquid_surface.dart';
import 'adaptive_glass_foreground.dart';
import 'glass_touch_shield.dart';
import 'liquid_content.dart';
import 'liquid_morphing_control.dart';
import 'liquid_motion_panel.dart';

/// Universal liquid substance: one widget for every liquid-glass case.
///
/// - drag physics is always the search reference: a single
///   [GlassMotionController] (plain buttons run it with `morphEnabled: false`,
///   i.e. a parked collapsed menu button);
/// - painting is always [GlassShell] (deformed) or [LiquidCase] (static);
/// - fixed/morph foreground follows via [LiquidContent]; panel bodies stay put;
/// - hit testing always absorbs behind the material via [GlassTouchShield]
///   in single-action mode.
///
/// Foreground: use AdaptiveGlassText/Icon for adaptive glyphs. Wrap ordinary
/// custom artwork in AdaptiveGlassDecoration to receive fades/motion blur
/// without inserting an offscreen buffer above the adaptive glyphs.
///
/// Modes:
/// - [LiquidGlass.fixed]: one material rect with arbitrary [child] inside —
///   a single button (`onTap != null`), a cluster of inner buttons
///   (`onTap == null`, children handle their own taps like the selection
///   toolbar pill), or a passive spot (`child` non-interactive).
/// - [LiquidGlass.morph]: the same substance flowing between [collapsed] and
///   [expanded] rects; content cross-fades with velocity blur.
/// - [LiquidGlass.panel]: content-sized panel; static by default. Opt into
///   [liquidMotion] for the same shell/physics with a stationary inner body.
class LiquidGlass extends StatelessWidget {
  const LiquidGlass.fixed({
    required this.child,
    required this.size,
    this.onTap,
    this.semanticsLabel,
    this.shapeTokens = const LiquidShapeTokens(),
    this.hitSlop = 8,
    super.key,
  }) : _kind = _LiquidKind.fixed,
       geometryBuilder = null,
       collapsedChild = null,
       expandedChild = null,
       collapsedSemanticsLabel = null,
       expandedSemanticsLabel = null,
       collapsedHitKey = null,
       onExpansionChanged = null,
       borderRadius = null,
       padding = EdgeInsets.zero,
       liquidMotion = false,
       fill = null;

  const LiquidGlass.morph({
    required this.geometryBuilder,
    required Widget this.collapsedChild,
    required Widget this.expandedChild,
    required String this.collapsedSemanticsLabel,
    this.expandedSemanticsLabel,
    this.collapsedHitKey,
    this.onExpansionChanged,
    this.hitSlop = 8,
    super.key,
  }) : _kind = _LiquidKind.morph,
       child = null,
       size = null,
       onTap = null,
       semanticsLabel = null,
       shapeTokens = const LiquidShapeTokens(),
       borderRadius = null,
       padding = EdgeInsets.zero,
       liquidMotion = false,
       fill = null;

  const LiquidGlass.panel({
    required this.child,
    this.borderRadius = 24,
    this.padding = EdgeInsets.zero,
    this.liquidMotion = false,
    this.fill,
    super.key,
  }) : _kind = _LiquidKind.panel,
       size = null,
       onTap = null,
       semanticsLabel = null,
       shapeTokens = const LiquidShapeTokens(),
       hitSlop = 8,
       geometryBuilder = null,
       collapsedChild = null,
       expandedChild = null,
       collapsedSemanticsLabel = null,
       expandedSemanticsLabel = null,
       collapsedHitKey = null,
       onExpansionChanged = null;

  final _LiquidKind _kind;

  // Fixed mode.
  final Widget? child;
  final Size? size;
  final VoidCallback? onTap;
  final String? semanticsLabel;
  final LiquidShapeTokens shapeTokens;
  final double hitSlop;

  // Morph mode.
  final LiquidMorphGeometry Function(Size viewport)? geometryBuilder;
  final Widget? collapsedChild;
  final Widget? expandedChild;
  final String? collapsedSemanticsLabel;
  final String? expandedSemanticsLabel;
  final Key? collapsedHitKey;
  final ValueChanged<bool>? onExpansionChanged;

  // Panel mode.
  final double? borderRadius;
  final EdgeInsetsGeometry padding;

  /// Deform only a panel's outer material; leave its inner content unchanged.
  final bool liquidMotion;

  /// Background fill color for the panel. Defaults to [LiquidCase]'s default.
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    switch (_kind) {
      case _LiquidKind.panel:
        if (liquidMotion) {
          return LiquidMotionPanel(
            borderRadius: borderRadius ?? 24,
            padding: padding,
            fill: fill,
            child: child!,
          );
        }
        return LiquidCase(
          borderRadius: borderRadius ?? 24,
          padding: padding,
          fill: fill ?? const Color(0xB31A1B1E),
          child: child!,
        );
      case _LiquidKind.morph:
        // Single morph implementation lives in LiquidMorphingControl; the
        // universal widget is a facade so search/morph/button never drift.
        return LiquidMorphingControl(
          geometryBuilder: geometryBuilder!,
          collapsedChild: collapsedChild!,
          expandedChild: expandedChild!,
          collapsedSemanticsLabel: collapsedSemanticsLabel!,
          expandedSemanticsLabel: expandedSemanticsLabel,
          collapsedHitKey: collapsedHitKey,
          onExpansionChanged: onExpansionChanged,
          hitSlop: hitSlop,
        );
      case _LiquidKind.fixed:
        return _LiquidFixedSurface(
          size: size!,
          onTap: onTap,
          semanticsLabel: semanticsLabel,
          shapeTokens: shapeTokens,
          hitSlop: hitSlop,
          child: child!,
        );
    }
  }
}

enum _LiquidKind { fixed, morph, panel }

/// Fixed-size liquid surface with search-tuned drag physics.
///
/// Self-contained: internally expands via [OverflowBox] so callers place a
/// tight [size] box without manual `+80` hacks (see former
/// `_LiquidChromeObject`). When [onTap] is null the surface is a passive
/// cluster container: no [GlassTouchShield] on top so inner buttons stay
/// alive (toolbar-pill pattern); otherwise the shield absorbs everything
/// behind the material.
class _LiquidFixedSurface extends StatefulWidget {
  const _LiquidFixedSurface({
    required this.child,
    required this.size,
    required this.shapeTokens,
    required this.hitSlop,
    this.onTap,
    this.semanticsLabel,
  });

  static const double paintPadding = 40;

  final Widget child;
  final Size size;
  final LiquidShapeTokens shapeTokens;
  final double hitSlop;
  final VoidCallback? onTap;
  final String? semanticsLabel;

  @override
  State<_LiquidFixedSurface> createState() => _LiquidFixedSurfaceState();
}

class _LiquidFixedSurfaceState extends State<_LiquidFixedSurface>
    with SingleTickerProviderStateMixin {
  // Same controller as the morphing menu/search reference, with morphing
  // disabled: tapSlop deadzone, live light origin, release impulse and
  // springs are literally the same code path as a collapsed menu button.
  late final GlassMotionController _motion;
  final FocusNode _focus = FocusNode(debugLabel: 'Liquid glass');
  int? _pointer;

  @override
  void initState() {
    super.initState();
    _motion = GlassMotionController(vsync: this, morphEnabled: false);
    _focus.addListener(_focusChanged);
  }

  void _focusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion.setLiquidMotionEnabled(
      FolioSettingsScope.liquidMotionEnabledOf(context),
    );
    _motion.setReducedMotion(MediaQuery.disableAnimationsOf(context));
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_focusChanged)
      ..dispose();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final shapeTokens = widget.shapeTokens;
    final hitSlop = widget.hitSlop;
    final onTap = widget.onTap;
    final motion = _motion;
    final focus = _focus;
    final boxSize = Size(
      size.width + _LiquidFixedSurface.paintPadding * 2,
      size.height + _LiquidFixedSurface.paintPadding * 2,
    );
    // Occupies exactly [size] in layout; the optical shell overflows it by
    // [paintPadding] on each side without clipping. The tight SizedBox keeps
    // unbounded parents (Row/Flex) happy, the inner OverflowBox lets the
    // shell breathe — no caller-side `+80` hacks needed.
    return SizedBox.fromSize(
      size: size,
      child: OverflowBox(
        minWidth: boxSize.width,
        maxWidth: boxSize.width,
        minHeight: boxSize.height,
        maxHeight: boxSize.height,
        alignment: Alignment.center,
        child: AnimatedBuilder(
          animation: motion,
          builder: (context, _) {
            final baseRect = Rect.fromCenter(
              center: (Offset.zero & boxSize).center,
              width: size.width,
              height: size.height,
            );
            final materialRect = LiquidShape.expandedRect(
              baseRect,
              press: motion.press,
              tokens: shapeTokens,
            );
            // Same origin/velocity rule as the morphing menu reference: the
            // deformation follows the live pointer light, velocity always feeds
            // the shape (no frozen press origin, no displacement gating).
            final light = motion.lightPosition == Offset.zero
                ? baseRect.center
                : motion.lightPosition;
            final path = GlassGeometryFrame.deformedCapsule(
              rect: materialRect,
              origin: light,
              pull: motion.displacement,
              velocity: motion.pointerVelocity,
              press: motion.press,
            );
            final contentOffset = LiquidContent.offset(
              displacement: motion.displacement,
              velocity: motion.pointerVelocity,
              press: motion.press,
            );
            final interactive = onTap != null;
            final transitionOpacity =
                LiquidBlurScope.maybeOpacityOf(context) ?? 1.0;
            // opaque MUST stay true: with false, MouseRegion reports a miss
            // upward even when its child was hit, ancestor Stacks keep
            // descending, and taps/drags leak to content behind the glass.
            return MouseRegion(
              cursor: interactive
                  ? SystemMouseCursors.click
                  : MouseCursor.defer,
              opaque: true,
              onHover: (event) => motion.updateHover(event.localPosition),
              child: Listener(
                behavior: interactive
                    ? HitTestBehavior.opaque
                    : HitTestBehavior.translucent,
                onPointerDown: (event) {
                  if (_pointer != null ||
                      !baseRect
                          .inflate(hitSlop)
                          .contains(event.localPosition)) {
                    return;
                  }
                  _pointer = event.pointer;
                  motion.beginPointer(
                    position: event.localPosition,
                    timestamp: event.timeStamp,
                    target: GlassPointerTarget.main,
                  );
                },
                onPointerMove: (event) {
                  if (_pointer == event.pointer) {
                    motion.movePointer(
                      position: event.localPosition,
                      timestamp: event.timeStamp,
                    );
                  }
                },
                onPointerUp: (event) {
                  if (_pointer != event.pointer) {
                    return;
                  }
                  final inside = baseRect
                      .inflate(hitSlop)
                      .contains(event.localPosition);
                  motion.endPointer(
                    position: event.localPosition,
                    timestamp: event.timeStamp,
                  );
                  _pointer = null;
                  if (inside) {
                    onTap?.call();
                  }
                },
                onPointerCancel: (event) {
                  if (_pointer == event.pointer) {
                    motion.cancelPointer();
                    _pointer = null;
                  }
                },
                child: Semantics(
                  button: interactive,
                  label: widget.semanticsLabel,
                  onTap: onTap,
                  child: Focus(
                    focusNode: focus,
                    canRequestFocus: interactive,
                    onKeyEvent: (node, event) {
                      if (onTap != null &&
                          event is KeyDownEvent &&
                          (event.logicalKey == LogicalKeyboardKey.enter ||
                              event.logicalKey == LogicalKeyboardKey.space)) {
                        onTap.call();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: SizedBox.fromSize(
                      size: boxSize,
                      child: AdaptiveGlassForegroundGroup(
                        samplePoint: adaptiveGlassSamplePoint(baseRect),
                        child: Stack(
                          fit: StackFit.expand,
                          children: <Widget>[
                            GlassShell(
                              path: path,
                              glowCenter: light,
                              press: motion.press,
                              focused: focus.hasFocus,
                              blurSigma: motion.backdropBlurSigma,
                            ),
                            // Passive/cluster glass has no TouchShield on top (it
                            // would eat inner buttons in the gesture arena);
                            // instead a non-competitive wall behind the content
                            // stops the traversal so nothing behind ever sees
                            // taps or drags started on the material.
                            if (!interactive) const GlassHitBlocker(),
                            AdaptiveGlassEffects(
                              opacity: transitionOpacity,
                              child: Center(
                                child: Transform.translate(
                                  offset: contentOffset,
                                  child: Transform.scale(
                                    scale: LiquidContent.scale(motion.press),
                                    child: widget.child,
                                  ),
                                ),
                              ),
                            ),
                            // Single-action glass absorbs behind it on top.
                            if (interactive) const GlassTouchShield(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
