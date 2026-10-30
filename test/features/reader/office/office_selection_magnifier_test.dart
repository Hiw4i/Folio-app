import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/reader/office/widgets/office_selection_magnifier.dart';

void main() {
  test(
    'Office loupe rejects inactive/nonfinite points and clamps viewport edges',
    () {
      for (final event in <Map<Object?, Object?>>[
        {},
        {'active': false, 'x': .2, 'y': .3},
        {'active': true, 'x': double.nan, 'y': .3},
        {'active': true, 'x': .2, 'y': double.infinity},
        {'active': true, 'x': '.2', 'y': .3},
      ]) {
        expect(officeSelectionMagnifierSource(event), isNull);
      }
      expect(
        officeSelectionMagnifierSource({'active': true, 'x': -1, 'y': 2}),
        const Offset(0, 1),
      );
    },
  );

  testWidgets(
    'Office loupe samples the same local point after rotation, insets and edge clamping',
    (tester) async {
      for (final size in [const Size(412, 800), const Size(800, 412)]) {
        await tester.binding.setSurfaceSize(size);
        for (final point in [
          const Offset(.5, .4),
          Offset.zero,
          const Offset(1, 1),
        ]) {
          await tester.pumpWidget(
            MaterialApp(
              home: Padding(
                padding: const EdgeInsets.fromLTRB(20, 35, 25, 45),
                child: OfficeSelectionMagnifier(normalizedSource: point),
              ),
            ),
          );
          final overlay = find.byType(OfficeSelectionMagnifier);
          final box = tester.getRect(overlay);
          final lens = find.byType(RawMagnifier);
          final raw = tester.widget<RawMagnifier>(lens);
          expect(
            tester.getCenter(lens) + raw.focalPointOffset,
            box.topLeft + Offset(point.dx * box.width, point.dy * box.height),
          );
          expect(box.contains(tester.getTopLeft(lens)), isTrue);
          expect(
            box.contains(tester.getBottomRight(lens) - const Offset(.01, .01)),
            isTrue,
          );
          expect(raw.magnificationScale, 1.25);
          expect(tester.takeException(), isNull);
        }
      }
      await tester.binding.setSurfaceSize(null);
    },
  );

  testWidgets('Office loupe leaves native handle gestures reachable', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => taps++,
              child: const SizedBox.expand(),
            ),
            const OfficeSelectionMagnifier(normalizedSource: Offset(.5, .5)),
          ],
        ),
      ),
    );
    await tester.tapAt(tester.getCenter(find.byType(RawMagnifier)));
    expect(taps, 1);
  });
}
