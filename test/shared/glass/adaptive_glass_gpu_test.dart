// Requires a real Impeller renderer; software widget tests cannot verify
// backdrop filters. Enforce that requirement with FOLIO_REQUIRE_GPU=true.
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/shared/glass/widgets/adaptive_glass_foreground.dart';
import 'package:folio/shared/glass/widgets/liquid_glass_control.dart';
import 'package:folio/shared/glass/widgets/liquid_morphing_control.dart';
import 'package:folio/shared/glass/surface/glass_shell.dart';
import 'package:folio/shared/settings/folio_settings.dart';
import 'package:folio/shared/settings/folio_settings_controller.dart';
import 'package:folio/shared/settings/folio_settings_scope.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../support/memory_settings_store.dart';

const _requireGpu = bool.fromEnvironment('FOLIO_REQUIRE_GPU');
const _sceneSize = Size(360, 240);
const _captureKey = ValueKey<String>('adaptive_gpu_scene');
const _textStyle = TextStyle(
  inherit: false,
  fontFamily: 'Inter',
  fontSize: 28,
  height: 1,
  fontWeight: FontWeight.w700,
);
late FolioSettingsController _settings;
double _pixelRatio = 1;

Widget _control({
  required double left,
  required String id,
  double opacity = 1,
  double sigma = 0,
  Offset translation = Offset.zero,
  bool retained = false,
}) => Positioned(
  left: left,
  top: 40,
  width: 150,
  height: 90,
  child: Transform.translate(
    offset: retained ? translation : Offset.zero,
    child: RepaintBoundary(
      child: AdaptiveGlassForegroundGroup(
        key: ValueKey<String>('group_$id'),
        samplePoint: const Offset(75, 8),
        child: AdaptiveGlassEffects(
          opacity: opacity,
          blurSigma: sigma,
          child: Transform.translate(
            offset: retained ? Offset.zero : translation,
            child: const Stack(
              children: <Widget>[
                Positioned(
                  left: 10,
                  top: 25,
                  width: 32,
                  height: 32,
                  child: AdaptiveGlassIcon(LucideIcons.search, size: 32),
                ),
                Positioned(
                  left: 52,
                  top: 25,
                  width: 90,
                  height: 34,
                  child: AdaptiveGlassText('MM', style: _textStyle),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
);

Widget _scene({
  Color background = const Color(0xFFFFFFFF),
  double opacity = 1,
  double sigma = 0,
  Offset translation = Offset.zero,
  bool split = false,
  bool retained = false,
  bool vertical = false,
}) => FolioSettingsScope(
  controller: _settings,
  child: MediaQuery(
    data: MediaQueryData(size: _sceneSize, devicePixelRatio: _pixelRatio),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: _captureKey,
        child: SizedBox.expand(
          child: ColoredBox(
            color: background,
            child: Stack(
              children: <Widget>[
                if (vertical)
                  const Positioned(
                    left: 0,
                    right: 0,
                    top: 120,
                    height: 120,
                    child: ColoredBox(color: Color(0xFF080808)),
                  ),
                if (split)
                  const Positioned(
                    left: 180,
                    top: 0,
                    width: 180,
                    height: 240,
                    child: ColoredBox(color: Color(0xFF080808)),
                  ),
                _control(
                  left: 10,
                  id: 'left',
                  opacity: opacity,
                  sigma: sigma,
                  translation: translation,
                  retained: retained,
                ),
                if (split)
                  _control(
                    left: 190,
                    id: 'right',
                    opacity: opacity,
                    sigma: sigma,
                    translation: translation,
                    retained: retained,
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
);

Future<ByteData> _pixels(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  final image = await boundary.toImage(pixelRatio: _pixelRatio);
  try {
    if (_pixelRatio == 1) {
      return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    }
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & _sceneSize,
      Paint(),
    );
    final picture = recorder.endRecording();
    final logical = await picture.toImage(360, 240);
    picture.dispose();
    try {
      return (await logical.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    } finally {
      logical.dispose();
    }
  } finally {
    image.dispose();
  }
}

({int minimum, int maximum}) _redRange(ByteData data, Rect rect) {
  var minimum = 255;
  var maximum = 0;
  for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
    for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
      final red = data.getUint8((y * 360 + x) * 4);
      if (red < minimum) minimum = red;
      if (red > maximum) maximum = red;
    }
  }
  return (minimum: minimum, maximum: maximum);
}

int _softInk(ByteData data, Rect rect) {
  var count = 0;
  for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
    for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
      final red = data.getUint8((y * 360 + x) * 4);
      if (red > 16 && red < 245) count++;
    }
  }
  return count;
}

void _setView(WidgetTester tester, {double pixelRatio = 1}) {
  _pixelRatio = pixelRatio;
  tester.view.devicePixelRatio = pixelRatio;
  tester.view.physicalSize = _sceneSize * pixelRatio;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Widget _readerScene() => FolioSettingsScope(
  controller: _settings,
  child: MediaQuery(
    data: MediaQueryData(size: _sceneSize, devicePixelRatio: _pixelRatio),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: _captureKey,
        child: ColoredBox(
          color: const Color(0xFFFFFFFF),
          child: BackdropGroup(
            child: Stack(
              children: <Widget>[
                Positioned(
                  left: 40,
                  top: 40,
                  child: LiquidGlassControl(
                    size: const Size(210, 48),
                    child: const AdaptiveGlassText('MM', style: _textStyle),
                  ),
                ),
                LiquidMorphingControl(
                  geometryBuilder: (_) => const LiquidMorphGeometry(
                    collapsedRect: Rect.fromLTWH(280, 40, 48, 48),
                    expandedRect: Rect.fromLTWH(130, 40, 198, 140),
                  ),
                  collapsedSemanticsLabel: 'Menu',
                  collapsedChild: const Center(
                    child: AdaptiveGlassIcon(LucideIcons.moreVertical),
                  ),
                  expandedChild: const Center(
                    child: AdaptiveGlassText('Menu', style: _textStyle),
                  ),
                ),
                const Positioned(
                  left: 20,
                  top: 180,
                  child: LiquidGlassControl(
                    size: Size(80, 48),
                    child: AdaptiveGlassText('MM', style: _textStyle),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
);

Widget _overlapScene() => FolioSettingsScope(
  controller: _settings,
  child: MediaQuery(
    data: MediaQueryData(size: _sceneSize, devicePixelRatio: _pixelRatio),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: _captureKey,
        child: ColoredBox(
          color: const Color(0xFFFFFFFF),
          child: BackdropGroup(
            child: Stack(
              children: <Widget>[
                Positioned(
                  left: 30,
                  top: 30,
                  width: 240,
                  height: 170,
                  child: GlassShell(
                    path: Path()..addRect(const Rect.fromLTWH(0, 0, 240, 170)),
                    glowCenter: Offset.zero,
                    press: 0,
                    focused: false,
                    fill: const Color(0xFF000000),
                  ),
                ),
                LiquidMorphingControl(
                  geometryBuilder: (_) => const LiquidMorphGeometry(
                    collapsedRect: Rect.fromLTWH(280, 40, 48, 48),
                    expandedRect: Rect.fromLTWH(130, 40, 198, 140),
                  ),
                  collapsedSemanticsLabel: 'Menu',
                  collapsedChild: const SizedBox.shrink(),
                  expandedChild: const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final supported = ui.ImageFilter.isShaderFilterSupported;

  setUpAll(() async {
    _settings = FolioSettingsController(
      store: MemorySettingsStore(const FolioSettings(blurEnabled: true)),
    );
    await _settings.load();
    if (!supported) return;
    // Use the project's real fonts, especially the Lucide search glyph, not
    // Flutter test's Ahem/tofu replacement. No font assets are copied by this patch.
    final manifest = jsonDecode(
      await rootBundle.loadString('FontManifest.json'),
    ) as List<dynamic>;
    for (final entry in manifest.cast<Map<String, dynamic>>()) {
      final loader = FontLoader(entry['family'] as String);
      for (final font
          in (entry['fonts'] as List<dynamic>).cast<Map<String, dynamic>>()) {
        loader.addFont(rootBundle.load(font['asset'] as String));
      }
      await loader.load();
    }
    await precacheAdaptiveGlassForeground();
  });
  tearDownAll(() => _settings.dispose());

  test(
    'strict GPU invocation cannot silently pass on the fallback renderer',
    () {
      if (_requireGpu) {
        expect(
          supported,
          isTrue,
          reason:
              'Run with --enable-impeller on a supported GPU runner. '
              'Skipping shader pixels is not validation.',
        );
      }
    },
  );

  testWidgets(
    'real engine samples the top of a vertically split Flutter backdrop',
    (tester) async {
      _setView(tester);
      await tester.pumpWidget(_scene(vertical: true));
      await tester.pump();
      expect(
        _redRange(
          await _pixels(tester),
          const Rect.fromLTWH(60, 62, 94, 38),
        ).minimum,
        lessThan(100),
      );
    },
    skip: !supported,
  );

  testWidgets(
    'expanded menu blurs the current surface when overlapping another control',
    (tester) async {
      _setView(tester);
      await tester.pumpWidget(_overlapScene());
      tester
          .state<LiquidMorphingControlState>(find.byType(LiquidMorphingControl))
          .open();
      await tester.pumpAndSettle();
      final pixels = await _pixels(tester);
      expect(
        _redRange(pixels, const Rect.fromLTWH(180, 80, 35, 35)).maximum,
        lessThan(100),
        reason:
            'The menu must sample the black control below it, not the '
            'white backdrop cached before that control was painted.',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !supported,
  );

  testWidgets(
    'GPU motion workload records timings without reallocating glyphs',
    (tester) async {
      _setView(tester, pixelRatio: 3);
      tester.view.physicalSize = const Size(1080, 2400);
      for (var i = 0; i < 8; i++) {
        await tester.pumpWidget(_scene(opacity: 0.7, sigma: 1.6));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final masks = AdaptiveGlassDebug.maskCreations;
      final shaders = AdaptiveGlassDebug.shaderCreations;
      // FrameTiming can contain no-op test frames. Explicit GPU readback makes
      // this a repeatable render+capture workload, not a claim about device FPS.
      final captures = <int>[];
      for (var i = 0; i < 24; i++) {
        await tester.pumpWidget(
          _scene(
            opacity: 0.7 + (i % 3) * 0.1,
            sigma: 1.2 + (i % 5) * 0.2,
            translation: Offset(i % 4 * 0.3, i % 3 * 0.2),
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(_captureKey),
        );
        final timer = Stopwatch()..start();
        final image = await boundary.toImage(pixelRatio: 3);
        try {
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        } finally {
          image.dispose();
        }
        captures.add(timer.elapsedMicroseconds);
      }
      captures.sort();
      debugPrint(
        'GPU_CAPTURE_BENCHMARK samples=${captures.length} '
        'capture_p50_us=${captures[captures.length ~/ 2]} '
        'capture_p90_us=${captures[(captures.length * 0.9).floor()]}',
      );
      expect(AdaptiveGlassDebug.maskCreations, masks);
      expect(AdaptiveGlassDebug.shaderCreations, shaders);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !supported,
  );

  testWidgets(
    'motion blur softens cached glyph alpha while preserving clear sample area',
    (tester) async {
      _setView(tester);
      await tester.pumpWidget(_scene());
      await tester.pump();
      final sharp = await _pixels(tester);
      await tester.pumpWidget(_scene(sigma: 1.6));
      await tester.pump();
      final soft = await _pixels(tester);
      const ink = Rect.fromLTWH(18, 62, 140, 45);
      expect(_softInk(soft, ink), greaterThan(_softInk(sharp, ink) + 20));
      expect(
        _redRange(soft, const Rect.fromLTWH(65, 44, 30, 9)).minimum,
        greaterThanOrEqualTo(254),
      );
    },
    skip: !supported,
  );

  testWidgets(
    'retained foreground follows an ancestor translation without repaint',
    (tester) async {
      _setView(tester);
      await tester.pumpWidget(_scene(retained: true));
      await tester.pump();
      for (final dy in <double>[16, 32, 0, -16]) {
        await tester.pumpWidget(
          _scene(retained: true, translation: Offset(0, dy)),
        );
        await tester.pump();
        final pixels = await _pixels(tester);
        expect(
          _redRange(pixels, Rect.fromLTWH(65, 68 + dy, 80, 14)).minimum,
          lessThan(100),
          reason: 'The entire glyph must follow the retained layer by $dy.',
        );
      }
    },
    skip: !supported,
  );

  testWidgets(
    'reader glass keeps complete glyphs at device density and during expansion',
    (tester) async {
      _setView(tester, pixelRatio: 3);
      await tester.pumpWidget(_readerScene());
      await tester.pumpAndSettle();
      final pixels = await _pixels(tester);
      // Both the top and bottom of the same MM label must survive. A minimum
      // over the entire label misses the screenshot's partially clipped ink.
      for (final rect in <Rect>[
        const Rect.fromLTWH(119, 52, 50, 10),
        const Rect.fromLTWH(119, 65, 50, 10),
        const Rect.fromLTWH(34, 192, 52, 10),
        const Rect.fromLTWH(34, 205, 52, 10),
      ]) {
        expect(_redRange(pixels, rect).minimum, lessThan(100), reason: '$rect');
      }
      final state = tester.state<LiquidMorphingControlState>(
        find.byType(LiquidMorphingControl),
      );
      state.open();
      await tester.pump();
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpAndSettle();
      final expanded = await _pixels(tester);
      expect(
        _redRange(expanded, const Rect.fromLTWH(185, 98, 90, 10)).minimum,
        lessThan(100),
      );
      expect(
        _redRange(expanded, const Rect.fromLTWH(185, 111, 90, 10)).minimum,
        lessThan(100),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !supported,
  );

  testWidgets(
    'actual search glyph and text stay black through fades and blur',
    (tester) async {
      _setView(tester);
      final before = AdaptiveGlassDebug.shaderCreations;
      for (final opacity in <double>[1, 0.88, 0.5, 0.25, 0.6, 1]) {
        await tester.pumpWidget(
          _scene(opacity: opacity, sigma: opacity == 1 ? 0 : 1.4),
        );
        await tester.pump();
        final pixels = await _pixels(tester);
        for (final rect in <Rect>[
          const Rect.fromLTWH(18, 62, 36, 38),
          const Rect.fromLTWH(60, 62, 94, 38),
        ]) {
          // A white-reset or missing glyph has no ink on the white scene.
          expect(_redRange(pixels, rect).minimum, lessThan(245));
        }
        expect(tester.takeException(), isNull);
      }
      expect(AdaptiveGlassDebug.shaderCreations - before, 2);
    },
    skip: !supported,
  );

  testWidgets('dark backgrounds keep white foreground during the same motion', (
    tester,
  ) async {
    _setView(tester);
    for (final opacity in <double>[1, 0.88, 0.25, 0.6, 1]) {
      await tester.pumpWidget(
        _scene(
          background: const Color(0xFF080808),
          opacity: opacity,
          sigma: opacity == 1 ? 0 : 1.4,
        ),
      );
      await tester.pump();
      final range = _redRange(
        await _pixels(tester),
        const Rect.fromLTWH(18, 62, 138, 38),
      );
      expect(range.maximum, greaterThan(20));
    }
  }, skip: !supported);

  testWidgets(
    'neighboring controls adapt independently, icon and label agree',
    (tester) async {
      _setView(tester);
      await tester.pumpWidget(_scene(split: true, opacity: 0.88));
      await tester.pump();
      final pixels = await _pixels(tester);
      for (final rect in <Rect>[
        const Rect.fromLTWH(18, 62, 36, 38),
        const Rect.fromLTWH(60, 62, 94, 38),
      ]) {
        expect(_redRange(pixels, rect).minimum, lessThan(100));
        expect(
          _redRange(pixels, rect.shift(const Offset(180, 0))).maximum,
          greaterThan(160),
        );
      }
    },
    skip: !supported,
  );

  testWidgets(
    'moving foreground reuses shaders and masks without a white frame',
    (tester) async {
      _setView(tester);
      await tester.pumpWidget(_scene());
      await tester.pump();
      final shaders = AdaptiveGlassDebug.shaderCreations;
      final masks = AdaptiveGlassDebug.maskCreations;
      for (var i = 0; i < 16; i++) {
        await tester.pumpWidget(
          _scene(
            opacity: 0.88,
            sigma: 1.2,
            translation: Offset(i * 0.2, i * 0.15),
          ),
        );
        await tester.pump();
        expect(
          _redRange(
            await _pixels(tester),
            const Rect.fromLTWH(18, 62, 144, 44),
          ).minimum,
          lessThan(230),
        );
      }
      expect(AdaptiveGlassDebug.shaderCreations, shaders);
      expect(AdaptiveGlassDebug.maskCreations, masks);
    },
    skip: !supported,
  );

  testWidgets(
    'foreground does not color the extra sample area or glass surface',
    (tester) async {
      _setView(tester);
      await tester.pumpWidget(_scene(opacity: 0.88, sigma: 1.4));
      await tester.pump();
      final pixels = await _pixels(tester);
      final clear = _redRange(pixels, const Rect.fromLTWH(65, 44, 30, 9));
      // Allow one 8-bit quantization step at coverage-mark boundaries.
      expect(clear.minimum, greaterThanOrEqualTo(254));
      await tester.pumpWidget(_scene(opacity: 0));
      await tester.pump();
      final hidden = _redRange(
        await _pixels(tester),
        const Rect.fromLTWH(15, 45, 145, 65),
      );
      expect(hidden.minimum, 255);
    },
    skip: !supported,
  );
}
