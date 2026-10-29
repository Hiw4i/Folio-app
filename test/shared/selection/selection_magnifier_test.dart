import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/shared/selection/selection_magnifier.dart';
import 'package:folio/shared/selection/selection_visuals.dart';

void main() {
  testWidgets('shared Android MD configuration retains the native lens style', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final info = ValueNotifier(
      MagnifierInfo(
        globalGesturePosition: const Offset(120, 220),
        caretRect: const Rect.fromLTWH(120, 200, 1, 20),
        fieldBounds: const Rect.fromLTWH(0, 0, 400, 600),
        currentLineBoundaries: const Rect.fromLTWH(0, 200, 400, 20),
      ),
    );
    addTearDown(info.dispose);
    final controller = MagnifierController();
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Builder(
              builder: (context) => folioTextMagnifierConfiguration
                  .magnifierBuilder(context, controller, info)!,
            ),
          ],
        ),
      ),
    );
    final lens = tester.widget<RawMagnifier>(find.byType(RawMagnifier));
    expect(lens.size, folioSelectionMagnifierSize);
    expect(lens.magnificationScale, folioSelectionMagnifierZoom);
    expect(
      (lens.decoration.shape as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(folioSelectionMagnifierCornerRadius),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('PDF lens uses the native MD Material capsule and tint', (
    tester,
  ) async {
    const reference = Magnifier();
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: FolioSelectionMagnifierFrame(
            child: ColoredBox(color: Colors.white),
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.byType(FolioSelectionMagnifierFrame)),
      reference.size,
    );
    final clip = tester.widget<ClipRRect>(find.byType(ClipRRect));
    expect(clip.borderRadius, reference.borderRadius);
    expect(clip.clipBehavior, reference.clipBehavior);
    final decoration =
        tester.widget<DecoratedBox>(find.byType(DecoratedBox)).decoration
            as ShapeDecoration;
    expect(decoration.shadows, reference.shadows);
    expect(
      (decoration.shape as RoundedRectangleBorder).borderRadius,
      reference.borderRadius,
    );
    expect(
      tester
          .widget<ColoredBox>(
            find.byKey(const ValueKey('selection_magnifier_film')),
          )
          .color,
      reference.filmColor,
    );
  });

  test('PDF magnifier samples at the MD scale at different document zooms', () {
    for (final zoom in [1.0, 2.0, .5]) {
      final source = folioSelectionMagnifierSourceRect(
        focalPoint: const Offset(100, 200),
        viewportZoom: zoom,
      );
      expect(source.center, const Offset(100, 200));
      expect(source.width * zoom, closeTo(61.896, .00001));
      expect(source.height * zoom, closeTo(30.32, .00001));
    }
  });
}
