import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../settings/folio_settings_scope.dart';
import 'adaptive_glass_effects.dart';

export 'adaptive_glass_effects.dart';

/// Fraction down from the top of a glass rect used as the shared backdrop
/// sample. One point per control keeps black/white stable; per-pixel sampling
/// would shimmer on gradients. Single helper so fixed/morph/search never drift.
const kAdaptiveSampleHeightFraction = 0.2;

/// Shared sample point near the top of [rect] (same 0.2 rule everywhere).
Offset adaptiveGlassSamplePoint(Rect rect) => Offset(
  rect.center.dx,
  rect.top + rect.height * kAdaptiveSampleHeightFraction,
);

/// Outline keeping white fallbacks readable on light backdrops. Shared by
/// [_OutlinedIcon] when shader filters are not supported.
const kAdaptiveOutlineShadows = <Shadow>[
  Shadow(color: Color(0xFF000000), blurRadius: 3),
  Shadow(color: Color(0xFF000000), blurRadius: 1),
];

bool get _shaderSupported =>
    AdaptiveGlassDebug.shaderFilterSupportedOverride ??
    ui.ImageFilter.isShaderFilterSupported;

/// Start loading once, before a reader/morph animation needs its first glyph.
/// Failures are handled by the same visible fallback as unsupported renderers.
Future<void> precacheAdaptiveGlassForeground() async {
  if (_shaderSupported) {
    await _AdaptiveGlassProgram.load();
  }
}

/// Defines one shared backdrop sample point for every adaptive glyph in a
/// liquid-glass control. The default is the center of this render box.
class AdaptiveGlassForegroundGroup extends SingleChildRenderObjectWidget {
  const AdaptiveGlassForegroundGroup({
    required super.child,
    this.samplePoint,
    super.key,
  });

  final Offset? samplePoint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderAdaptiveGlassGroup(samplePoint);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    final group = renderObject as _RenderAdaptiveGlassGroup;
    group.samplePoint = samplePoint;
  }
}

class _RenderAdaptiveGlassGroup extends RenderProxyBox {
  _RenderAdaptiveGlassGroup(this._samplePoint);

  Offset? _samplePoint;

  set samplePoint(Offset? value) {
    if (value == _samplePoint) {
      return;
    }
    _samplePoint = value;
    markNeedsPaint();
  }

  Offset get globalSamplePoint =>
      localToGlobal(_samplePoint ?? (Offset.zero & size).center);

  // Coordinates are refreshed by the foreground layer at composition time.
  // An ancestor may retain this subtree while moving its RepaintBoundary.
}

/// An icon whose black/white foreground is computed by the GPU from the
/// shared sample point of its nearest [AdaptiveGlassForegroundGroup].
///
/// The widget never reads pixels back to the CPU and never schedules tone
/// updates. Each painted frame therefore reflects the current backdrop.
///
/// The shader uses a common black/white tone for the control (with a narrow
/// luminance crossover); unsupported renderers use the outlined white icon.
class AdaptiveGlassIcon extends StatelessWidget {
  const AdaptiveGlassIcon(
    this.icon, {
    this.size = 24,
    this.semanticLabel,
    super.key,
  });

  final IconData icon;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    if (!FolioSettingsScope.blurEnabledOf(context)) {
      return AdaptiveGlassDecoration(
        child: Icon(
          icon,
          size: size,
          semanticLabel: semanticLabel,
          color: const Color(0xFFFFFFFF),
        ),
      );
    }
    final shaderSupported =
        AdaptiveGlassDebug.shaderFilterSupportedOverride ??
        ui.ImageFilter.isShaderFilterSupported;
    if (!shaderSupported) {
      return AdaptiveGlassDecoration(
        child: _OutlinedIcon(
          icon: icon,
          size: size,
          semanticLabel: semanticLabel,
        ),
      );
    }
    final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
    Widget glyph = AdaptiveGlassText(
      String.fromCharCode(icon.codePoint),
      textDirection: direction,
      semanticsLabel: semanticLabel ?? '',
      textScaler: TextScaler.noScaling,
      style: TextStyle(
        inherit: false,
        color: const Color(0xFFFFFFFF),
        fontSize: size,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
        fontFamilyFallback: icon.fontFamilyFallback,
        height: 1,
        leadingDistribution: TextLeadingDistribution.even,
      ),
    );
    if (icon.matchTextDirection && direction == TextDirection.rtl) {
      glyph = Transform.flip(flipX: true, child: glyph);
    }
    return Semantics(
      label: semanticLabel,
      excludeSemantics: true,
      child: SizedBox.square(dimension: size, child: glyph),
    );
  }
}

/// Text whose whole black/white foreground is computed by the GPU from the
/// shared sample point of its nearest [AdaptiveGlassForegroundGroup].
///
/// [style.color] and [style.shadows] are ignored: the glyph mask is always
/// built white and the shader decides the visible tone. Unsupported renderers
/// use white text, so callers must not rely on a custom color.
class AdaptiveGlassText extends StatelessWidget {
  const AdaptiveGlassText(
    this.data, {
    required this.style,
    this.maxLines = 1,
    this.overflow,
    this.softWrap = true,
    this.textAlign,
    this.textDirection,
    this.textScaler,
    this.semanticsLabel,
    super.key,
  });

  final String data;
  final TextStyle style;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool softWrap;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final TextScaler? textScaler;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
    final direction = textDirection ?? Directionality.of(context);
    final scaler = textScaler ?? MediaQuery.textScalerOf(context);
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final fallback = _OutlinedText(
      data: data,
      style: effectiveStyle,
      maxLines: maxLines,
      overflow: overflow,
      softWrap: softWrap,
      textAlign: textAlign,
      textDirection: direction,
      textScaler: scaler,
      semanticsLabel: semanticsLabel,
    );
    if (!FolioSettingsScope.blurEnabledOf(context) || !_shaderSupported) {
      return AdaptiveGlassDecoration(child: fallback);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final layoutWidth =
            (softWrap || overflow == TextOverflow.ellipsis) &&
                constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : double.infinity;
        final painter = _textPainter(
          data: data,
          style: effectiveStyle,
          direction: direction,
          scaler: scaler,
          maxLines: maxLines,
          overflow: overflow,
          textAlign: textAlign,
        );
        late final Size size;
        try {
          painter.layout(maxWidth: layoutWidth);
          size = constraints.constrain(painter.size);
        } finally {
          painter.dispose();
        }
        final key = _TextMaskKey(
          data,
          _maskStyle(effectiveStyle),
          direction,
          scaler,
          maxLines,
          overflow,
          textAlign,
          size,
          pixelRatio,
          softWrap: softWrap,
        );
        return Semantics(
          label: semanticsLabel ?? data,
          excludeSemantics: true,
          child: SizedBox.fromSize(
            size: size,
            child: _AdaptiveMaskSurface(
              maskKey: key,
              createMask: () => _createTextMask(key),
              fallback: fallback,
            ),
          ),
        );
      },
    );
  }
}

TextStyle _maskStyle(TextStyle style) => style.copyWith(
  color: const Color(0xFFFFFFFF),
  backgroundColor: const Color(0x00000000),
  shadows: const <Shadow>[],
);

TextPainter _textPainter({
  required String data,
  required TextStyle style,
  required TextDirection direction,
  required TextScaler scaler,
  required int? maxLines,
  required TextOverflow? overflow,
  required TextAlign? textAlign,
}) {
  return TextPainter(
    text: TextSpan(text: data, style: _maskStyle(style)),
    textDirection: direction,
    textScaler: scaler,
    maxLines: maxLines,
    ellipsis: overflow == TextOverflow.ellipsis ? '\u2026' : null,
    textAlign: textAlign ?? TextAlign.start,
    textWidthBasis: TextWidthBasis.parent,
  );
}

class _AdaptiveMaskSurface extends StatefulWidget {
  const _AdaptiveMaskSurface({
    required this.maskKey,
    required this.createMask,
    required this.fallback,
  });

  final _MaskKey maskKey;
  final ui.Image Function() createMask;
  final Widget fallback;

  @override
  State<_AdaptiveMaskSurface> createState() => _AdaptiveMaskSurfaceState();
}

class _AdaptiveMaskSurfaceState extends State<_AdaptiveMaskSurface> {
  ui.Image? _mask;
  int _programRequest = 0;

  bool get _shaderSupported =>
      AdaptiveGlassDebug.shaderFilterSupportedOverride ??
      ui.ImageFilter.isShaderFilterSupported;

  @override
  void initState() {
    super.initState();
    if (_shaderSupported) {
      _acquireMask();
    }
    _loadProgram();
  }

  @override
  void didUpdateWidget(_AdaptiveMaskSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.maskKey != widget.maskKey) {
      if (_mask != null) {
        _releaseMask(oldWidget.maskKey);
      }
      if (_shaderSupported) {
        _acquireMask();
      }
    }
    // Fallback is consumed directly by build; no resource update needed.
  }

  void _acquireMask() {
    final size = widget.maskKey.logicalSize;
    if (size.isEmpty || !size.isFinite) {
      return;
    }
    try {
      _mask = _GlassMaskCache.acquire(widget.maskKey, widget.createMask);
    } on Object catch (error) {
      // A mask allocation failure must leave readable, tappable content.
      debugPrint('Adaptive glass mask unavailable: $error');
    }
  }

  void _releaseMask(_MaskKey key) {
    _GlassMaskCache.release(key);
    _mask = null;
  }

  Future<void> _loadProgram() async {
    if (!_shaderSupported || _AdaptiveGlassProgram.program != null) {
      return;
    }
    final request = ++_programRequest;
    final program = await _AdaptiveGlassProgram.load();
    if (!mounted || request != _programRequest || program == null) {
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _programRequest++;
    if (_mask != null) {
      _releaseMask(widget.maskKey);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final program = _AdaptiveGlassProgram.program;
    final effects = AdaptiveGlassEffects.of(context);
    final fallback = AdaptiveGlassDecoration(child: widget.fallback);
    if (program == null || _mask == null) {
      return fallback;
    }
    // Exclusive fallback, NOT a white glyph underneath an adaptive one.
    // Double-painting the antialiased edge caused pale fringes; an opacity
    // layer above the old backdrop also exposed that white underlay in motion.
    return _AdaptiveBackdrop(
      program: program,
      mask: _mask!,
      devicePixelRatio: widget.maskKey.pixelRatio,
      effects: effects,
      child: fallback,
    );
  }
}

class _AdaptiveBackdrop extends SingleChildRenderObjectWidget {
  const _AdaptiveBackdrop({
    required this.program,
    required this.mask,
    required this.devicePixelRatio,
    required this.effects,
    required super.child,
  });

  final ui.FragmentProgram program;
  final ui.Image mask;
  final double devicePixelRatio;
  final AdaptiveGlassEffectData effects;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderAdaptiveBackdrop(program, mask, devicePixelRatio, effects);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderAdaptiveBackdrop renderObject,
  ) {
    renderObject
      ..program = program
      ..mask = mask
      ..devicePixelRatio = devicePixelRatio
      ..effects = effects;
  }
}

class _RenderAdaptiveBackdrop extends RenderProxyBox {
  _RenderAdaptiveBackdrop(
    this._program,
    this._mask,
    this._devicePixelRatio,
    this._effects,
  );

  ui.FragmentProgram _program;
  ui.Image _mask;
  double _devicePixelRatio;
  AdaptiveGlassEffectData _effects;
  List<double>? _lastUniforms;
  ui.FragmentShader? _shader;
  ui.Image? _boundMask;
  ui.ImageFilter? _filter;
  Rect _filterBounds = Rect.zero;
  bool _filterCreationFailed = false;
  final LayerHandle<_AdaptiveForegroundLayer> _backdropLayer =
      LayerHandle<_AdaptiveForegroundLayer>();

  set program(ui.FragmentProgram value) {
    if (identical(value, _program)) return;
    _program = value;
    _shader?.dispose();
    _shader = null;
    _boundMask = null;
    _filterCreationFailed = false;
    _invalidateFilter();
  }

  set mask(ui.Image value) {
    if (identical(value, _mask)) return;
    _mask = value;
    _filterCreationFailed = false;
    _invalidateFilter();
  }

  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    _invalidateFilter();
  }

  set effects(AdaptiveGlassEffectData value) {
    if (value == _effects) return;
    _effects = value;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  void _invalidateFilter() {
    _lastUniforms = null;
    _filter = null;
    // A failed backend is not retried on every opacity/motion tick. A new
    // program or mask permits a retry; otherwise use the readable fallback.
    markNeedsPaint();
  }

  bool _ensureFilter() {
    if (size.isEmpty || !_devicePixelRatio.isFinite || _devicePixelRatio <= 0) {
      return false;
    }
    final transform = getTransformTo(null);
    Offset physical(Offset point) =>
        MatrixUtils.transformPoint(transform, point) * _devicePixelRatio;
    final origin = physical(Offset.zero);
    final xAxis = physical(Offset(size.width, 0)) - origin;
    final yAxis = physical(Offset(0, size.height)) - origin;
    final determinant = xAxis.dx * yAxis.dy - yAxis.dx * xAxis.dy;
    if (!determinant.isFinite || determinant.abs() < 1e-8) return false;

    final group = _findGroup();
    final sample =
        (group?.globalSamplePoint ??
            localToGlobal((Offset.zero & size).center)) *
        _devicePixelRatio;
    final localSample = globalToLocal(sample / _devicePixelRatio);
    if (!origin.isFinite || !sample.isFinite || !localSample.isFinite) {
      return false;
    }
    // Include the shared sample patch in filter input coverage. Clipping to
    // just a 24x24 glyph can crop away the sample above that glyph entirely.
    // Outside the mask the shader returns transparent: this extra coverage
    // does not tint, blur or otherwise recolor the glass surface.
    // Three *physical* pixels of source coverage, even under a scale/flip.
    final sampleHalfWidth =
        3 * size.width * (yAxis.dy.abs() + yAxis.dx.abs()) / determinant.abs();
    final sampleHalfHeight =
        3 * size.height * (xAxis.dy.abs() + xAxis.dx.abs()) / determinant.abs();
    _filterBounds = (Offset.zero & size)
        .inflate(_effects.blurSigma * 3 + 1)
        .expandToInclude(
          Rect.fromCenter(
            center: localSample,
            width: sampleHalfWidth * 2,
            height: sampleHalfHeight * 2,
          ),
        );
    final blurSigma = (_effects.blurSigma * 10).roundToDouble() / 10;
    final uniforms = <double>[
      origin.dx,
      origin.dy,
      yAxis.dy / determinant,
      -yAxis.dx / determinant,
      -xAxis.dy / determinant,
      xAxis.dx / determinant,
      sample.dx,
      sample.dy,
      _effects.opacity,
      blurSigma / size.width,
      blurSigma / size.height,
    ];
    if (listEquals(uniforms, _lastUniforms)) {
      return _filter != null;
    }
    if (_filterCreationFailed) return false;
    try {
      // Reuse the native shader and layers. ImageFilter takes a uniform
      // snapshot, so create that lightweight filter only when values change.
      final shader = _shader ??= _createShader();
      for (var index = 0; index < uniforms.length; index++) {
        shader.setFloat(index + 2, uniforms[index]);
      }
      if (!identical(_boundMask, _mask)) {
        shader.setImageSampler(1, _mask, filterQuality: FilterQuality.low);
        _boundMask = _mask;
      }
      _filter = ui.ImageFilter.shader(shader);
      _lastUniforms = uniforms;
      return true;
    } on Object catch (error) {
      _filter = null;
      _filterCreationFailed = true;
      debugPrint('Adaptive glass filter unavailable: $error');
      return false;
    }
  }

  ui.FragmentShader _createShader() {
    assert(() {
      AdaptiveGlassDebug.shaderCreations++;
      return true;
    }());
    return _program.fragmentShader();
  }

  _RenderAdaptiveGlassGroup? _findGroup() {
    RenderObject? ancestor = parent;
    while (ancestor != null) {
      if (ancestor is _RenderAdaptiveGlassGroup) return ancestor;
      ancestor = ancestor.parent;
    }
    return null;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_effects.opacity <= 0) {
      // Hidden glyphs keep their mask/state but submit no backdrop pass.
      _backdropLayer.layer = null;
      return;
    }
    if (!_ensureFilter()) {
      _backdropLayer.layer = null;
      super.paint(context, offset);
      return;
    }
    final backdrop = _backdropLayer.layer ??= _AdaptiveForegroundLayer(this);
    backdrop.paintOffset = offset;
    context.pushLayer(
      backdrop,
      (context, offset) {},
      offset,
      childPaintBounds: _filterBounds.shift(offset),
    );
  }

  @override
  void dispose() {
    _backdropLayer.layer = null;
    _shader?.dispose();
    super.dispose();
  }
}

/// Refresh only scene-dependent uniforms, even when Flutter retains the
/// render subtree beneath a moving ancestor. No layout, glyph rasterization,
/// post-frame callback or subtree invalidation is needed for this update.
class _AdaptiveForegroundLayer extends ContainerLayer {
  _AdaptiveForegroundLayer(this.renderObject);

  final _RenderAdaptiveBackdrop renderObject;
  Offset paintOffset = Offset.zero;
  ui.BackdropFilterEngineLayer? _filterLayer;
  ui.Picture? _coverage;
  Rect? _coverageBounds;
  static final Paint _coveragePaint = Paint()
    ..color = const Color.fromARGB(1, 0, 0, 0);

  @override
  bool get alwaysNeedsAddToScene => true;

  @override
  void addToScene(ui.SceneBuilder builder) {
    if (!renderObject.attached || !renderObject._ensureFilter()) return;
    engineLayer = builder.pushClipRect(
      renderObject._filterBounds.shift(paintOffset),
      oldLayer: engineLayer as ui.ClipRectEngineLayer?,
    );
    final previous = _filterLayer;
    _filterLayer = builder.pushBackdropFilter(
      renderObject._filter!,
      oldLayer: previous,
    );
    previous?.dispose();
    final bounds = renderObject._filterBounds;
    if (bounds != _coverageBounds) {
      // The shared sample can move independently of a retained glyph. Keep
      // input coverage current as well as its shader uniforms and output clip.
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawPoints(ui.PointMode.points, <Offset>[
        bounds.topLeft,
        bounds.topRight,
        bounds.bottomLeft,
        bounds.bottomRight,
      ], _coveragePaint);
      _coverage?.dispose();
      _coverage = recorder.endRecording();
      _coverageBounds = bounds;
    }
    builder.addPicture(paintOffset, _coverage!);
    builder.pop();
    builder.pop();
  }

  @override
  void dispose() {
    _filterLayer?.dispose();
    _filterLayer = null;
    _coverage?.dispose();
    _coverage = null;
    super.dispose();
  }
}

class _AdaptiveGlassProgram {
  static const asset = 'assets/shaders/adaptive_glass_foreground.frag';
  static Future<ui.FragmentProgram?>? _loading;
  static ui.FragmentProgram? program;

  static Future<ui.FragmentProgram?> load() {
    return _loading ??= ui.FragmentProgram.fromAsset(asset)
        .then<ui.FragmentProgram?>((value) {
          program = value;
          return value;
        })
        .onError((Object error, StackTrace stackTrace) {
          debugPrint('Adaptive glass shader unavailable: $error');
          return null;
        });
  }
}

/// Test hook for forcing the safe path without depending on the renderer used
/// by the test process. Production code leaves this null.
abstract final class AdaptiveGlassDebug {
  @visibleForTesting
  static bool? shaderFilterSupportedOverride;

  @visibleForTesting
  static int shaderCreations = 0;

  @visibleForTesting
  static int maskCreations = 0;

  @visibleForTesting
  static int get cachedMaskBytes => _GlassMaskCache._bytes;

  @visibleForTesting
  static int get cachedMaskCount => _GlassMaskCache._entries.length;

  @visibleForTesting
  static Future<bool> textMaskHasCoverage() async {
    const key = _TextMaskKey(
      'Glass',
      TextStyle(fontSize: 16, color: Color(0xFFFFFFFF)),
      TextDirection.ltr,
      TextScaler.noScaling,
      1,
      null,
      null,
      Size(64, 24),
      1,
    );
    final image = _createTextMask(key);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    if (bytes == null) {
      return false;
    }
    return _hasCoverageAndTransparency(bytes);
  }

  @visibleForTesting
  static Future<bool> iconMaskHasCoverage(IconData icon) async {
    final image = _createTextMask(
      _TextMaskKey(
        String.fromCharCode(icon.codePoint),
        TextStyle(
          inherit: false,
          color: const Color(0xFFFFFFFF),
          fontSize: 24,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontFamilyFallback: icon.fontFamilyFallback,
          height: 1,
          leadingDistribution: TextLeadingDistribution.even,
        ),
        TextDirection.ltr,
        TextScaler.noScaling,
        1,
        null,
        null,
        const Size.square(24),
        1,
      ),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    if (bytes == null) {
      return false;
    }
    return _hasCoverageAndTransparency(bytes);
  }
}

bool _hasCoverageAndTransparency(ByteData bytes) {
  var hasCoverage = false;
  var hasTransparency = false;
  for (var index = 3; index < bytes.lengthInBytes; index += 4) {
    final alpha = bytes.getUint8(index);
    hasCoverage |= alpha != 0;
    hasTransparency |= alpha != 255;
    if (hasCoverage && hasTransparency) {
      break;
    }
  }
  return hasCoverage && hasTransparency;
}

sealed class _MaskKey {
  const _MaskKey(this.logicalSize, this.pixelRatio);

  final Size logicalSize;
  final double pixelRatio;
}

class _TextMaskKey extends _MaskKey {
  const _TextMaskKey(
    this.data,
    this.style,
    this.direction,
    this.scaler,
    this.maxLines,
    this.overflow,
    this.textAlign,
    Size logicalSize,
    double pixelRatio, {
    this.softWrap = true,
  }) : super(logicalSize, pixelRatio);

  final String data;
  final TextStyle style;
  final TextDirection direction;
  final TextScaler scaler;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  final bool softWrap;

  @override
  bool operator ==(Object other) =>
      other is _TextMaskKey &&
      other.data == data &&
      other.style == style &&
      other.direction == direction &&
      other.scaler == scaler &&
      other.maxLines == maxLines &&
      other.overflow == overflow &&
      other.textAlign == textAlign &&
      other.logicalSize == logicalSize &&
      other.pixelRatio == pixelRatio &&
      other.softWrap == softWrap;

  @override
  int get hashCode => Object.hash(
    data,
    style,
    direction,
    scaler,
    maxLines,
    overflow,
    textAlign,
    logicalSize,
    pixelRatio,
    softWrap,
  );
}

class _MaskEntry {
  _MaskEntry(this.image) : references = 1;

  final ui.Image image;
  int references;
}

abstract final class _GlassMaskCache {
  static const _maximumEntries = 64;
  static const _maximumCachedBytes = 8 * 1024 * 1024;
  static int _bytes = 0;
  static final LinkedHashMap<_MaskKey, _MaskEntry> _entries =
      LinkedHashMap<_MaskKey, _MaskEntry>();

  static ui.Image acquire(_MaskKey key, ui.Image Function() create) {
    final existing = _entries.remove(key);
    if (existing != null) {
      existing.references++;
      _entries[key] = existing;
      return existing.image;
    }
    final entry = _MaskEntry(create());
    assert(() {
      AdaptiveGlassDebug.maskCreations++;
      return true;
    }());
    _entries[key] = entry;
    _bytes += entry.image.width * entry.image.height * 4;
    _trim();
    return entry.image;
  }

  static void release(_MaskKey key) {
    final entry = _entries[key];
    if (entry == null) {
      return;
    }
    entry.references = (entry.references - 1).clamp(0, 1 << 30);
    _trim();
  }

  static void _trim() {
    if (_entries.length <= _maximumEntries && _bytes <= _maximumCachedBytes) {
      return;
    }
    for (final key in _entries.keys.toList(growable: false)) {
      if (_entries.length <= _maximumEntries && _bytes <= _maximumCachedBytes) {
        break;
      }
      final entry = _entries[key]!;
      if (entry.references == 0) {
        _entries.remove(key);
        _bytes -= entry.image.width * entry.image.height * 4;
        entry.image.dispose();
      }
    }
  }
}

ui.Image _createTextMask(_TextMaskKey key) {
  final width = (key.logicalSize.width * key.pixelRatio).ceil();
  final height = (key.logicalSize.height * key.pixelRatio).ceil();
  if (width < 1 ||
      height < 1 ||
      width > 8192 ||
      height > 8192 ||
      width * height > 4 * 1024 * 1024) {
    throw StateError('Adaptive glyph exceeds the mask allocation budget');
  }
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(key.pixelRatio);
  canvas.clipRect(Offset.zero & key.logicalSize);
  final painter = _textPainter(
    data: key.data,
    style: key.style,
    direction: key.direction,
    scaler: key.scaler,
    maxLines: key.maxLines,
    overflow: key.overflow,
    textAlign: key.textAlign,
  );
  ui.Picture? picture;
  try {
    painter.layout(
      maxWidth: key.softWrap || key.overflow == TextOverflow.ellipsis
          ? key.logicalSize.width
          : double.infinity,
    );
    painter.paint(canvas, Offset.zero);
    picture = recorder.endRecording();
    return picture.toImageSync(width, height);
  } finally {
    painter.dispose();
    picture?.dispose();
    if (recorder.isRecording) recorder.endRecording().dispose();
  }
}

class _OutlinedIcon extends StatelessWidget {
  const _OutlinedIcon({
    required this.icon,
    required this.size,
    this.semanticLabel,
  });

  final IconData icon;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Icon(
      icon,
      size: size,
      color: const Color(0xFFFFFFFF),
      semanticLabel: semanticLabel,
      shadows: kAdaptiveOutlineShadows,
    );
  }
}

class _OutlinedText extends StatelessWidget {
  const _OutlinedText({
    required this.data,
    required this.style,
    required this.maxLines,
    required this.overflow,
    required this.softWrap,
    required this.textAlign,
    required this.textDirection,
    required this.textScaler,
    required this.semanticsLabel,
  });

  final String data;
  final TextStyle style;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool softWrap;
  final TextAlign? textAlign;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return Text(
      data,
      semanticsLabel: semanticsLabel,
      maxLines: maxLines,
      overflow: overflow,
      softWrap: softWrap,
      textAlign: textAlign,
      textDirection: textDirection,
      textScaler: textScaler,
      style: style.copyWith(
        color: const Color(0xFFFFFFFF),
        shadows: FolioSettingsScope.blurEnabledOf(context)
            ? kAdaptiveOutlineShadows
            : const <Shadow>[],
      ),
    );
  }
}
