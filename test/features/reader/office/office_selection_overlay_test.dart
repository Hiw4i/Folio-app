import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/reader/office/widgets/office_selection_overlay.dart';
import 'package:folio/shared/selection/folio_selection_toolbar.dart';

void main() {
  test('selection snapshot rejects inactive or invalid coordinates', () {
    for (final event in <Map<Object?, Object?>>[
      <Object?, Object?>{},
      <Object?, Object?>{'active': false},
      <Object?, Object?>{
        'active': true,
        'x': double.nan,
        'top': .2,
        'bottom': .3,
      },
      <Object?, Object?>{
        'active': true,
        'x': .5,
        'top': double.infinity,
        'bottom': .3,
      },
      <Object?, Object?>{'active': true, 'x': '0.5', 'top': .2, 'bottom': .3},
    ]) {
      expect(
        OfficeSelectionSnapshot.fromEvent(event),
        OfficeSelectionSnapshot.empty,
      );
    }
  });

  test('selection coordinates clamp and equal snapshots deduplicate', () {
    const expected = OfficeSelectionSnapshot(
      active: true,
      showMenu: true,
      x: 1,
      top: 0,
      bottom: 1,
    );
    final actual = OfficeSelectionSnapshot.fromEvent(<Object?, Object?>{
      'active': true,
      'showMenu': true,
      'x': 2,
      'top': -1,
      'bottom': 1,
    });
    expect(actual, expected);
    expect(actual.hashCode, expected.hashCode);
  });

  testWidgets(
    'Office uses the same pill and normalized anchors after rotation',
    (tester) async {
      for (final size in <Size>[const Size(412, 915), const Size(915, 412)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpWidget(
          MaterialApp(
            home: OfficeSelectionOverlay(
              selection: const OfficeSelectionSnapshot(
                active: true,
                showMenu: true,
                x: .5,
                top: .25,
                bottom: .3,
              ),
              onCopy: () {},
              onSelectAll: () {},
            ),
          ),
        );
        await tester.pump();
        final toolbar = tester.widget<FolioSelectionToolbar>(
          find.byType(FolioSelectionToolbar),
        );
        expect(
          toolbar.anchors.primaryAnchor,
          Offset(size.width / 2, size.height / 4),
        );
        expect(
          toolbar.anchors.secondaryAnchor,
          Offset(size.width / 2, size.height * .3),
        );
        expect(tester.takeException(), isNull);
      }
      await tester.binding.setSurfaceSize(null);
    },
  );

  testWidgets('Office pill handles Copy and Select all once each', (
    tester,
  ) async {
    var copies = 0, selections = 0, documentTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => documentTaps++,
              child: const SizedBox.expand(),
            ),
            OfficeSelectionOverlay(
              selection: const OfficeSelectionSnapshot(
                active: true,
                showMenu: true,
              ),
              onCopy: () => copies++,
              onSelectAll: () => selections++,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('folio_toolbar_copy')));
    await tester.tap(
      find.byKey(const ValueKey<String>('folio_toolbar_select_all')),
    );
    await tester.tapAt(const Offset(25, 450));
    expect(copies, 1);
    expect(selections, 1);
    expect(documentTaps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden selection pill does not leave an invisible hit barrier', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: OfficeSelectionOverlay(
          selection: const OfficeSelectionSnapshot(
            active: true,
            showMenu: false,
          ),
          onCopy: () {},
          onSelectAll: () {},
        ),
      ),
    );
    expect(find.byType(FolioSelectionToolbar), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
