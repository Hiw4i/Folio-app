import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../settings/folio_settings_scope.dart';

import '../../theme/folio_theme.dart';
import '../core/glass_geometry.dart';
import '../core/liquid_shape.dart';
import '../motion/liquid_segmented_controller.dart';
import '../surface/glass_shell.dart';
import '../surface/liquid_surface.dart';
import 'adaptive_glass_foreground.dart';

@immutable
class LiquidSegment<T> {
  const LiquidSegment({required this.value, required this.label});

  final T value;
  final String label;
}

class LiquidSegmentedControl<T> extends StatefulWidget {
  const LiquidSegmentedControl({
    required this.segments,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final List<LiquidSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  State<LiquidSegmentedControl<T>> createState() =>
      _LiquidSegmentedControlState<T>();
}

class _LiquidSegmentedControlState<T> extends State<LiquidSegmentedControl<T>>
    with SingleTickerProviderStateMixin {
  static const double _height = 54;
  static const double _lensInset = 4;

  /// Линза при перелёте не только тянется по горизонтали, но и равномерно
  /// растёт во все стороны (эффект приближения к экрану).
  /// travelGrowth здесь заметно больше дефолтных 0.09 из LiquidShape,
  /// чтобы вертикальный рост был виден, а не только горизонтальный стретч.
  /// Press не задаём: равномерный pressPadding из дефолта одинаково
  /// приподнимает линзу по вертикали и горизонтали.
  static const LiquidShapeTokens _lensShape = LiquidShapeTokens(
    travelGrowth: 0.26,
    travelStretch: 0.34,
  );
  // Максимальная высота линзы: разрешаем вылет за трек (_height),
  // иначе clamp срежет зум и останется только горизонтальный рост.
  static const double _maxLensHeight = _height + 20;

  late final LiquidSegmentedController _motion;
  int? _pointer;
  int? _focusedIndex;

  int get _selectedIndex {
    final index = widget.segments.indexWhere(
      (segment) => segment.value == widget.selected,
    );
    assert(index >= 0, 'selected must match one segment');
    return math.max(0, index);
  }

  @override
  void initState() {
    super.initState();
    assert(widget.segments.isNotEmpty);
    _motion = LiquidSegmentedController(
      initialIndex: _selectedIndex,
      itemCount: widget.segments.length,
      vsync: this,
    );
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
  void didUpdateWidget(covariant LiquidSegmentedControl<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(oldWidget.segments.length == widget.segments.length);
    if (oldWidget.selected != widget.selected) {
      _motion.select(_selectedIndex);
    }
  }

  void _select(int index) {
    _motion.select(index);
    if (index != _selectedIndex) {
      widget.onSelected(widget.segments[index].value);
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, _height);
          return AnimatedBuilder(
            animation: _motion,
            builder: (context, child) {
              final segmentWidth = size.width / widget.segments.length;
              final centerX = segmentWidth * (_motion.position + 0.5);
              final baseWidth = segmentWidth - _lensInset * 2;
              final materialRect = LiquidShape.expandedRect(
                Rect.fromCenter(
                  center: Offset(centerX, size.height / 2),
                  width: baseWidth,
                  height: 44,
                ),
                press: _motion.press * (_motion.isDraggingLens ? 1 : 0.22),
                travel: _motion.stretch,
                tokens: _lensShape,
              );
              final availableHalfWidth = math.max(
                baseWidth / 2,
                math.min(centerX, size.width - centerX),
              );
              final lensWidth = math.min(
                materialRect.width,
                availableHalfWidth * 2,
              );
              final lensHeight = math.min(
                materialRect.height,
                _maxLensHeight,
              );
              final lensRect = Rect.fromCenter(
                center: Offset(centerX, size.height / 2),
                width: lensWidth,
                height: lensHeight,
              );
              return MouseRegion(
                cursor: SystemMouseCursors.click,
                onHover: (event) => _motion.updateHover(event.localPosition),
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) {
                    if (_pointer != null) {
                      return;
                    }
                    _pointer = event.pointer;
                    _motion.beginPointer(
                      position: event.localPosition,
                      timestamp: event.timeStamp,
                      itemExtent: segmentWidth,
                      dragLens: lensRect
                          .inflate(8)
                          .contains(event.localPosition),
                    );
                  },
                  onPointerMove: (event) {
                    if (_pointer == event.pointer) {
                      _motion.movePointer(
                        position: event.localPosition,
                        timestamp: event.timeStamp,
                        itemExtent: segmentWidth,
                      );
                    }
                  },
                  onPointerUp: (event) {
                    if (_pointer == event.pointer) {
                      final index = _motion.endPointer(
                        position: event.localPosition,
                        timestamp: event.timeStamp,
                        itemExtent: segmentWidth,
                      );
                      _pointer = null;
                      _select(index);
                    }
                  },
                  onPointerCancel: (event) {
                    if (_pointer == event.pointer) {
                      _pointer = null;
                      _motion.cancelPointer(_selectedIndex);
                    }
                  },
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: <Widget>[
                      const Positioned.fill(child: LiquidCase.track()),
                      _LiquidLens(
                        rect: lensRect,
                        motion: _motion,
                        focused: _focusedIndex != null,
                      ),
                      // Без motion-blur: лейблы сегментов всегда чёткие, блюрится
                      // только само стекло (линза/трек) через BackdropFilter.
                      Positioned.fill(
                        child: Row(
                          children: <Widget>[
                            for (
                              var index = 0;
                              index < widget.segments.length;
                              index++
                            )
                              Expanded(
                                child: _SegmentLabel(
                                  label: widget.segments[index].label,
                                  selected:
                                      1 -
                                      (_motion.position - index).abs().clamp(
                                        0.0,
                                        1.0,
                                      ),
                                  onTap: () => _select(index),
                                  onFocusChanged: (focused) {
                                    setState(() {
                                      if (focused) {
                                        _focusedIndex = index;
                                      } else if (_focusedIndex == index) {
                                        _focusedIndex = null;
                                      }
                                    });
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _LiquidLens extends StatelessWidget {
  const _LiquidLens({
    required this.rect,
    required this.motion,
    required this.focused,
  });

  static const double _paintPadding = 34;
  final Rect rect;
  final LiquidSegmentedController motion;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final shellRect = rect.inflate(_paintPadding);
    final localRect = rect.shift(-shellRect.topLeft);
    final pointerInside = rect.inflate(8).contains(motion.lightPosition);
    final localPointer = pointerInside
        ? motion.lightPosition - shellRect.topLeft
        : localRect.center;
    final travelDirection = motion.velocity == 0 ? 0.0 : motion.velocity.sign;
    final deformation = Offset(
      travelDirection * motion.stretch * math.min(8, rect.width * 0.09),
      0,
    );
    final path = GlassGeometryFrame.deformedCapsule(
      rect: localRect,
      origin: localPointer,
      pull: deformation,
      velocity: Offset(motion.velocity * 70, 0),
      press: motion.press * (pointerInside ? 1 : 0.22),
    );
    return Positioned.fromRect(
      rect: shellRect,
      child: GlassShell(
        path: path,
        glowCenter: localPointer,
        press: motion.press * (pointerInside ? 1 : 0.22),
        focused: focused,
        blurSigma: motion.backdropBlurSigma,
      ),
    );
  }
}

class _SegmentLabel extends StatelessWidget {
  const _SegmentLabel({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.onFocusChanged,
  });

  final String label;
  final double selected;
  final VoidCallback onTap;
  final ValueChanged<bool> onFocusChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected > 0.94,
      label: '$label documents',
      onTap: onTap,
      child: Focus(
        onFocusChange: onFocusChanged,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.space)) {
            onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            return AdaptiveGlassForegroundGroup(
              samplePoint: adaptiveGlassSamplePoint(
                Offset.zero &
                    Size(
                      constraints.maxWidth,
                      _LiquidSegmentedControlState._height,
                    ),
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: AdaptiveGlassText(
                      label,
                      maxLines: 1,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        color: appColors.textPrimary,
                        fontSize: 13.5,
                        fontWeight: selected > 0.58
                            ? FontWeight.w600
                            : FontWeight.w500,
                        letterSpacing: -0.12,
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
