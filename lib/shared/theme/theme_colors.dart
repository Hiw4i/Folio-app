import 'package:flutter/widgets.dart';

import '../diagnostics/app_log.dart';
import 'app_colors.dart';
import 'glass_colors.dart';

/// Stateful scope that animates [AppColors] and [GlassColors] transitions
/// via [Color.lerp] when the theme changes (god_mode's ThemeColors pattern).
///
/// Every theme-aware widget reads `context.colors` / `context.glass` instead
/// of a global palette, so a light/dark switch cross-fades the whole app.
class ThemeColors extends StatefulWidget {
  const ThemeColors({
    required this.colors,
    required this.glass,
    required this.child,
    this.duration = Duration.zero,
    super.key,
  });

  final AppColors colors;
  final GlassColors glass;
  final Widget child;

  /// [Duration.zero] (reduced motion) switches palettes instantly.
  final Duration duration;

  @override
  State<ThemeColors> createState() => _ThemeColorsState();
}

class _ThemeColorsState extends State<ThemeColors>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  _Transition? _previous;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..addListener(_onTick);
  }

  @override
  void didUpdateWidget(ThemeColors oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    if (identical(oldWidget.colors, widget.colors) &&
        identical(oldWidget.glass, widget.glass)) {
      return;
    }
    if (widget.duration == Duration.zero) {
      _controller.stop();
      _previous = null;
      return;
    }
    // A switch while a transition runs starts from the previous target, not
    // the current interpolation — a snap nobody can perceive at this pace.
    _previous = _Transition(colors: oldWidget.colors, glass: oldWidget.glass);
    _controller.forward(from: 0);
  }

  void _onTick() => setState(() {});

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  _Transition get _effective {
    final previous = _previous;
    if (previous == null || !_controller.isAnimating) {
      _previous = null;
      return _Transition(colors: widget.colors, glass: widget.glass);
    }
    return _Transition(
      colors: _AnimAppColors(previous.colors, widget.colors, _controller.value),
      glass: _AnimGlassColors(previous.glass, widget.glass, _controller.value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final effective = _effective;
    return _InheritedThemeColors(
      colors: effective.colors,
      glass: effective.glass,
      child: widget.child,
    );
  }
}

class _Transition {
  const _Transition({required this.colors, required this.glass});

  final AppColors colors;
  final GlassColors glass;
}

class _InheritedThemeColors extends InheritedWidget {
  const _InheritedThemeColors({
    required this.colors,
    required this.glass,
    required super.child,
  });

  final AppColors colors;
  final GlassColors glass;

  @override
  bool updateShouldNotify(_InheritedThemeColors oldWidget) =>
      oldWidget.colors != colors || oldWidget.glass != glass;
}

AppColors _colorsOf(BuildContext context) {
  final scope = context
      .dependOnInheritedWidgetOfExactType<_InheritedThemeColors>();
  if (scope == null) {
    // The documented fallback for isolated controls and tests. Loud in
    // debug so a forgotten scope above a real screen is discoverable
    // instead of silently painting the wrong theme.
    assert(() {
      AppLog.w(
        'ThemeColors scope is missing above $context; '
        'falling back to the dark palette.',
      );
      return true;
    }());
    return darkAppColors;
  }
  return scope.colors;
}

GlassColors _glassOf(BuildContext context) {
  final scope = context
      .dependOnInheritedWidgetOfExactType<_InheritedThemeColors>();
  if (scope == null) {
    assert(() {
      AppLog.w(
        'ThemeColors scope is missing above $context; '
        'falling back to the dark glass.',
      );
      return true;
    }());
    return darkGlassColors;
  }
  return scope.glass;
}

/// Content and interaction roles for the current theme.
extension ThemeColorsContext on BuildContext {
  AppColors get colors => _colorsOf(this);

  GlassColors get glass => _glassOf(this);
}

class _AnimAppColors implements AppColors {
  _AnimAppColors(this._begin, this._end, this._t);

  final AppColors _begin;
  final AppColors _end;
  final double _t;

  Color _lerp(Color a, Color b) => Color.lerp(a, b, _t)!;

  @override
  Color get background => _lerp(_begin.background, _end.background);

  @override
  Color get surface => _lerp(_begin.surface, _end.surface);

  @override
  Color get primary => _lerp(_begin.primary, _end.primary);

  @override
  Color get secondary => _lerp(_begin.secondary, _end.secondary);

  @override
  Color get border => _lerp(_begin.border, _end.border);

  @override
  Color get scrim => _lerp(_begin.scrim, _end.scrim);

  @override
  Color get selection => _lerp(_begin.selection, _end.selection);

  @override
  Color get selectionHandle =>
      _lerp(_begin.selectionHandle, _end.selectionHandle);

  @override
  Color get cursor => _lerp(_begin.cursor, _end.cursor);

  @override
  Color get searchMatch => _lerp(_begin.searchMatch, _end.searchMatch);

  @override
  Color get activeSearchMatch =>
      _lerp(_begin.activeSearchMatch, _end.activeSearchMatch);

  @override
  Color get activeSearchText =>
      _lerp(_begin.activeSearchText, _end.activeSearchText);
}

class _AnimGlassColors implements GlassColors {
  _AnimGlassColors(this._begin, this._end, this._t);

  final GlassColors _begin;
  final GlassColors _end;
  final double _t;

  Color _lerp(Color a, Color b) => Color.lerp(a, b, _t)!;

  List<Color> _lerpList(List<Color> a, List<Color> b) => List<Color>.generate(
    a.length,
    (index) => Color.lerp(a[index], b[index], _t)!,
  );

  @override
  bool get isLight => _end.isLight;

  @override
  Color get opaqueFill => _lerp(_begin.opaqueFill, _end.opaqueFill);

  @override
  Color get surfaceFill => _lerp(_begin.surfaceFill, _end.surfaceFill);

  @override
  Color get trackFill => _lerp(_begin.trackFill, _end.trackFill);

  @override
  List<Color> get rimColors => _lerpList(_begin.rimColors, _end.rimColors);

  @override
  List<Color> get overlayColors =>
      _lerpList(_begin.overlayColors, _end.overlayColors);
}
