import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/shared/glass/surface/glass_shell.dart';
import 'package:folio/shared/glass/surface/liquid_surface.dart';
import 'package:folio/shared/glass/surface/liquid_surface_style.dart';
import 'package:folio/shared/settings/folio_settings.dart';
import 'package:folio/shared/settings/folio_settings_controller.dart';
import 'package:folio/shared/settings/folio_settings_scope.dart';
import 'package:folio/shared/theme/glass_colors.dart';

import '../../support/memory_settings_store.dart';

void main() {
  test('rim reflection is uneven and has no angular seam', () {
    final rimColors = darkGlassColors.rimColors;
    expect(rimColors.first, rimColors.last);
    final opacities = rimColors.map((color) => color.a).toList()..sort();
    expect(opacities.last - opacities.first, greaterThan(0.4));
    expect(
      darkGlassColors.opaqueFill.computeLuminance(),
      greaterThan(const Color(0xFF202123).computeLuminance()),
    );
    expect(darkGlassColors.opaqueFill.a, 1);
  });

  testWidgets('blur-off shell retains its inner edge and lighter opaque fill', (
    tester,
  ) async {
    final controller = FolioSettingsController(
      store: MemorySettingsStore(const FolioSettings(blurEnabled: false)),
    );
    await controller.load();
    addTearDown(controller.dispose);
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(20, 20, 120, 60),
          const Radius.circular(20),
        ),
      );
    await tester.pumpWidget(
      FolioSettingsScope(
        controller: controller,
        child: MaterialApp(
          home: Center(
            child: SizedBox(
              width: 160,
              height: 100,
              child: GlassShell(
                path: path,
                glowCenter: const Offset(80, 50),
                press: 0,
                focused: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
      isFalse,
    );
    final shellPaints = tester.widgetList<CustomPaint>(
      find.descendant(
        of: find.byType(GlassShell),
        matching: find.byType(CustomPaint),
      ),
    );
    expect(
      shellPaints.first.painter,
      isNull,
    ); // No outer shadow in blur-off mode.
    final material = shellPaints.last.painter!;
    final pixels = await tester.runAsync(() => _paintPixels(material));
    expect(pixels, isNotNull);
    final data = pixels!;
    final center = (50 * 160 + 80) * 4;
    final edge = (50 * 160 + 22) * 4;
    expect(data[center], 0x29);
    expect(data[center + 1], 0x2A);
    expect(data[center + 2], 0x2D);
    expect(data[center + 3], 255);
    expect(data[edge], greaterThan(data[center]));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'static panels use the shared rim without changing content inset',
    (tester) async {
      final controller = FolioSettingsController(
        store: MemorySettingsStore(const FolioSettings(blurEnabled: false)),
      );
      await controller.load();
      addTearDown(controller.dispose);
      const caseKey = ValueKey<String>('case');
      const childKey = ValueKey<String>('case_child');
      await tester.pumpWidget(
        FolioSettingsScope(
          controller: controller,
          child: MaterialApp(
            home: Center(
              child: SizedBox(
                width: 220,
                height: 100,
                child: LiquidCase(
                  key: caseKey,
                  padding: const EdgeInsets.all(10),
                  child: const SizedBox.expand(key: childKey),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<CustomPaint>(
              find.descendant(
                of: find.byKey(caseKey),
                matching: find.byType(CustomPaint),
              ),
            )
            .where((paint) => paint.foregroundPainter is LiquidCaseRimPainter),
        hasLength(1),
      );
      final decorations = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byKey(caseKey),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((widget) => widget.decoration)
          .whereType<BoxDecoration>();
      expect(
        decorations.any((box) => box.color == darkGlassColors.opaqueFill),
        isTrue,
      );
      expect(decorations.every((box) => box.border == null), isTrue);
      final origin = tester.getTopLeft(find.byKey(caseKey));
      final childOrigin = tester.getTopLeft(find.byKey(childKey));
      expect(childOrigin.dx - origin.dx, closeTo(10, 0.001));
      expect(childOrigin.dy - origin.dy, closeTo(10, 0.001));
      // An opaque panel skips the backdrop pipeline entirely: the filter
      // stays mounted as a passthrough with nothing to sample.
      expect(
        tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('painted rim contains bright and dark sections', (tester) async {
    final pixels = await tester.runAsync(() => _paintPixels(_RimProbe()));
    expect(pixels, isNotNull);
    // Points on the same circular stroke, at opposing light/dark angles.
    final data = pixels!;
    final upperLeftAlpha = data[(32 * 160 + 32) * 4 + 3];
    final lowerLeftAlpha = data[(88 * 160 + 32) * 4 + 3];
    expect(upperLeftAlpha, greaterThan(lowerLeftAlpha * 4));
  });

  test('case rim never intercepts pointer events', () {
    final painter = LiquidCaseRimPainter(
      radius: const BorderRadius.all(Radius.circular(24)),
      rimColors: darkGlassColors.rimColors,
    );
    expect(painter.hitTest(Offset.zero), isFalse);
    expect(painter.shouldRepaint(painter), isFalse);
    expect(
      painter.shouldRepaint(
        LiquidCaseRimPainter(
          radius: const BorderRadius.all(Radius.circular(12)),
          rimColors: darkGlassColors.rimColors,
        ),
      ),
      isTrue,
    );
  });
}

Future<List<int>> _paintPixels(CustomPainter painter) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), const Size(160, 100));
  final picture = recorder.endRecording();
  final image = await picture.toImage(160, 100);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return bytes!.buffer.asUint8List().toList(growable: false);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

class _RimProbe extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const bounds = Rect.fromLTWH(20, 20, 80, 80);
    LiquidSurfaceStyle.paintRim(
      canvas,
      Path()..addOval(bounds),
      bounds: bounds,
      rimColors: darkGlassColors.rimColors,
      width: 4,
    );
  }

  @override
  bool shouldRepaint(covariant _RimProbe oldDelegate) => false;
}
