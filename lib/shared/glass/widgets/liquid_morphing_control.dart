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

@immutable
class LiquidMorphGeometry {
  const LiquidMorphGeometry({
    required this.collapsedRect,
    required this.expandedRect,
    this.expandedCornerRadius = 24,
  });

  final Rect collapsedRect;
  final Rect expandedRect;
  final double expandedCornerRadius;
}

typedef LiquidMorphGeometryBuilder = LiquidMorphGeometry Function(
  Size viewport,
);

/// A reusable one-piece liquid surface that can contain arbitrary collapsed
/// and expanded content. It owns the spring, deformation, focus, hit testing
/// and outside-tap dismissal; feature widgets only supply geometry and content.
class LiquidMorphingControl extends StatefulWidget {
  const LiquidMorphingControl({
    required this.geometryBuilder,
    required this.collapsedChild,
    required this.expandedChild,
    required this.collapsedSemanticsLabel,
    this.expandedSemanticsLabel,
    this.collapsedHitKey,
    this.onExpansionChanged,
    this.hitSlop = 8,
    super.key,
  });

  final LiquidMorphGeometryBuilder geometryBuilder;
  final Widget collapsedChild;
  final Widget expandedChild;
  final String collapsedSemanticsLabel;
  final String? expandedSemanticsLabel;
  final Key? collapsedHitKey;
  final ValueChanged<bool>? onExpansionChanged;
  final double hitSlop;

  @override
  State<LiquidMorphingControl> createState() => LiquidMorphingControlState();
}

class LiquidMorphingControlState extends State<LiquidMorphingControl>
    with SingleTickerProviderStateMixin {
  static const double _opticalPadding = 42;
  static const LiquidShapeTokens _morphShape = LiquidShapeTokens(
    travelGrowth: 0.035,
    travelStretch: 0.08,
  );

  late final GlassMotionController _motion;
  final FocusNode _focus = FocusNode(debugLabel: 'Liquid morph control');
  int? _pointer;
  bool _reportedExpanded = false;
  bool _reducedMotion = false;

  bool get isExpanded => _motion.wantsOpen || _motion.morph > 0.02;

  void open() => _motion.requestOpen();

  void close() => _motion.requestClose();

  @override
  void initState() {
    super.initState();
    _motion = GlassMotionController(vsync: this)..addListener(_motionChanged);
    _focus.addListener(_focusChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion.setLiquidMotionEnabled(
      FolioSettingsScope.liquidMotionEnabledOf(context),
    );
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    _motion.setReducedMotion(_reducedMotion);
  }

  void _motionChanged() {
    if (_reportedExpanded == _motion.wantsOpen) {
      return;
    }
    _reportedExpanded = _motion.wantsOpen;
    widget.onExpansionChanged?.call(_reportedExpanded);
  }

  void _focusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_focusChanged)
      ..dispose();
    _motion
      ..removeListener(_motionChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        final geometry = widget.geometryBuilder(viewport);
        return AnimatedBuilder(
          animation: _motion,
          builder: (context, child) {
            final rawMorph = _motion.morph.clamp(-0.035, 1.065);
            final opacityMorph = rawMorph.clamp(0.0, 1.0);
            final morph = LiquidShape.visualMorph(rawMorph);
            final contentMorph = LiquidShape.contentMorph(rawMorph);
            final travel = (4 * opacityMorph * (1 - opacityMorph)).clamp(
              0.0,
              1.0,
            );
            final baseRect = Rect.lerp(
              geometry.collapsedRect,
              geometry.expandedRect,
              morph,
            )!;
            final contentRect = Rect.lerp(
              geometry.collapsedRect,
              geometry.expandedRect,
              contentMorph,
            )!;
            final materialRect = LiquidShape.expandedRect(
              baseRect,
              press: _motion.press,
              travel: travel,
              tokens: _morphShape,
            );
            final radius = _lerp(
              geometry.collapsedRect.height / 2,
              geometry.expandedCornerRadius,
              morph,
            );
            final settleDeformation = Offset(
              _motion.settleWobble,
              -_motion.settleWobble * 0.16,
            );
            final deformation = _motion.displacement + settleDeformation;
            final opticalBounds = materialRect.inflate(
              _opticalPadding + deformation.distance,
            );
            final origin = _motion.lightPosition == Offset.zero
                ? materialRect.center
                : _motion.lightPosition;
            final localPath = GlassGeometryFrame.deformedRoundedRect(
              rect: materialRect.shift(-opticalBounds.topLeft),
              radius: radius,
              origin: origin - opticalBounds.topLeft,
              pull: deformation,
              velocity: _motion.pointerVelocity,
              press: _motion.press,
            );
            final contentOffset = LiquidShape.contentOffset(
              displacement: deformation,
              velocity: _motion.pointerVelocity,
              press: _motion.press,
            );
            final collapsedOpacity = (1 - ((opacityMorph - 0.22) / 0.56)).clamp(
              0.0,
              1.0,
            );
            final expandedOpacity = ((opacityMorph - 0.38) / 0.42).clamp(
              0.0,
              1.0,
            );
            final transitionOpacity =
                LiquidBlurScope.maybeOpacityOf(context) ?? 1.0;
            final selfBlur = LiquidContent.blurSigma(
              morphVelocity: _motion.morphVelocity,
              separationVelocity: _motion.separationVelocity,
              reducedMotion: _reducedMotion,
            );

            Widget soften(Widget value) => AdaptiveGlassEffects(
              blurSigma: FolioSettingsScope.blurEnabledOf(context)
                  ? selfBlur
                  : 0,
              child: value,
            );

            return AdaptiveGlassForegroundGroup(
              samplePoint: adaptiveGlassSamplePoint(materialRect),
              child: Listener(
                behavior: HitTestBehavior.deferToChild,
                onPointerDown: (event) {
                  if (_pointer != null ||
                      !materialRect
                          .inflate(widget.hitSlop)
                          .contains(event.localPosition)) {
                    return;
                  }
                  _pointer = event.pointer;
                  _motion.beginPointer(
                    position: event.localPosition,
                    timestamp: event.timeStamp,
                    target: GlassPointerTarget.main,
                  );
                },
                onPointerMove: (event) {
                  if (_pointer == event.pointer) {
                    _motion.movePointer(
                      position: event.localPosition,
                      timestamp: event.timeStamp,
                    );
                  }
                },
                onPointerUp: (event) {
                  if (_pointer == event.pointer) {
                    _motion.endPointer(
                      position: event.localPosition,
                      timestamp: event.timeStamp,
                    );
                    _pointer = null;
                  }
                },
                onPointerCancel: (event) {
                  if (_pointer == event.pointer) {
                    _motion.cancelPointer();
                    _pointer = null;
                  }
                },
                child: Stack(
                  fit: StackFit.expand,
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    if (isExpanded)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: close,
                          child: const ColoredBox(color: Color(0x01000000)),
                        ),
                      ),
                    Positioned.fromRect(
                      rect: opticalBounds,
                      child: GlassShell(
                        path: localPath,
                        glowCenter: origin - opticalBounds.topLeft,
                        press: _motion.press,
                        focused: _focus.hasFocus,
                        blurSigma: _motion.backdropBlurSigma,
                      ),
                    ),
                    Positioned.fromRect(
                      rect: materialRect.inflate(widget.hitSlop),
                      child: const GlassTouchShield(),
                    ),
                    Positioned.fromRect(
                      rect: opticalBounds,
                      child: ClipPath(
                        clipper: _MorphPathClipper(localPath),
                        child: Stack(
                          fit: StackFit.expand,
                          children: <Widget>[
                            Positioned.fromRect(
                              rect: contentRect.shift(-opticalBounds.topLeft),
                              child: IgnorePointer(
                                child: ExcludeSemantics(
                                  child: soften(
                                    AdaptiveGlassEffects(
                                      opacity:
                                          collapsedOpacity * transitionOpacity,
                                      child: Transform.translate(
                                        offset: contentOffset,
                                        child: Transform.scale(
                                          scale: LiquidShape.contentScale(
                                            _motion.press,
                                          ),
                                          child: widget.collapsedChild,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (isExpanded ||
                                _motion.state != GlassInteractionState.idle)
                              Positioned.fromRect(
                                rect: geometry.expandedRect.shift(
                                  -opticalBounds.topLeft,
                                ),
                                child: IgnorePointer(
                                  ignoring: morph < 0.82,
                                  child: ExcludeSemantics(
                                    excluding: morph < 0.82,
                                    child: soften(
                                      AdaptiveGlassEffects(
                                        opacity:
                                            expandedOpacity * transitionOpacity,
                                        child: Transform.translate(
                                          offset: contentOffset,
                                          child: widget.expandedChild,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (morph < 0.72)
                      Positioned.fromRect(
                        rect: geometry.collapsedRect.inflate(widget.hitSlop),
                        child: GestureDetector(
                          key: widget.collapsedHitKey,
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            if (!_motion.wantsOpen) {
                              open();
                            }
                          },
                          child: Semantics(
                            button: true,
                            label: widget.collapsedSemanticsLabel,
                            onTap: open,
                            child: Focus(
                              focusNode: _focus,
                              onKeyEvent: (node, event) {
                                if (event is KeyDownEvent &&
                                    (event.logicalKey ==
                                            LogicalKeyboardKey.enter ||
                                        event.logicalKey ==
                                            LogicalKeyboardKey.space)) {
                                  open();
                                  return KeyEventResult.handled;
                                }
                                return KeyEventResult.ignored;
                              },
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ),
                    if (morph >= 0.72 && widget.expandedSemanticsLabel != null)
                      Positioned.fromRect(
                        rect: geometry.expandedRect,
                        child: IgnorePointer(
                          child: Semantics(
                            container: true,
                            explicitChildNodes: true,
                            label: widget.expandedSemanticsLabel,
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}

class _MorphPathClipper extends CustomClipper<Path> {
  const _MorphPathClipper(this.path);

  final Path path;

  @override
  Path getClip(Size size) => path;

  @override
  bool shouldReclip(covariant _MorphPathClipper oldClipper) =>
      oldClipper.path != path;
}
