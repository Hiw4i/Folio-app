import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/shared/selection/folio_selection_toolbar.dart';
import 'package:folio/shared/widgets/scale_reveal.dart';
import 'package:folio/features/reader/office/widgets/office_selection_overlay.dart';

void main() {
  testWidgets('unsupported replacement exits the previous pill normally', (
    tester,
  ) async {
    final supported = ValueNotifier(true);
    addTearDown(supported.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => FolioSelectionToolbarHost(child: child!),
        home: ValueListenableBuilder<bool>(
          valueListenable: supported,
          builder: (context, value, _) => FolioSelectionToolbar(
            anchors: const TextSelectionToolbarAnchors(
              primaryAnchor: Offset(200, 200),
            ),
            buttonItems: [
              ContextMenuButtonItem(
                type: value
                    ? ContextMenuButtonType.copy
                    : ContextMenuButtonType.share,
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    supported.value = false;
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('folio_toolbar_copy')), findsOneWidget);
    expect(
      tester.widget<ScaleReveal>(find.byType(ScaleReveal)).visible,
      isFalse,
    );
    await tester.pumpAndSettle();
    expect(find.byType(ScaleReveal), findsNothing);
  });

  testWidgets(
    'Office visibility uses the retained exit and fresh coordinates',
    (tester) async {
      final selection = ValueNotifier(
        const OfficeSelectionSnapshot(
          active: true,
          showMenu: true,
          x: .5,
          top: .3,
          bottom: .35,
        ),
      );
      addTearDown(selection.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => FolioSelectionToolbarHost(child: child!),
          home: ValueListenableBuilder<OfficeSelectionSnapshot>(
            valueListenable: selection,
            builder: (context, value, _) => OfficeSelectionOverlay(
              selection: value,
              onCopy: () {},
              onSelectAll: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final copy = find.byKey(const ValueKey('folio_toolbar_copy'));
      final before = tester.getCenter(copy);
      selection.value = const OfficeSelectionSnapshot(
        active: true,
        showMenu: true,
        x: .5,
        top: .5,
        bottom: .55,
      );
      await tester.pumpAndSettle();
      expect(tester.getCenter(copy).dy, greaterThan(before.dy + 50));
      selection.value = OfficeSelectionSnapshot.empty;
      await tester.pump();
      await tester.pump();
      expect(copy, findsOneWidget);
      await tester.pumpAndSettle();
      expect(copy, findsNothing);
    },
  );

  testWidgets('host preserves local coordinates inside an offset viewport', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => FolioSelectionToolbarHost(child: child!),
        home: Padding(
          padding: const EdgeInsets.only(top: 80, left: 60),
          child: FolioSelectionToolbar(
            anchors: const TextSelectionToolbarAnchors(
              primaryAnchor: Offset(200, 200),
            ),
            buttonItems: [
              ContextMenuButtonItem(
                type: ContextMenuButtonType.copy,
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final copy = find.byKey(const ValueKey('folio_toolbar_copy'));
    expect(tester.getCenter(copy).dx, closeTo(260, 1));
    expect(tester.getCenter(copy).dy, closeTo(250, 1));
  });
  testWidgets('framework removal keeps an inert pill until exit settles', (
    tester,
  ) async {
    final shown = ValueNotifier(true);
    addTearDown(shown.dispose);
    var copies = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => FolioSelectionToolbarHost(child: child!),
        home: ValueListenableBuilder<bool>(
          valueListenable: shown,
          builder: (context, value, _) => value
              ? FolioSelectionToolbar(
                  anchors: const TextSelectionToolbarAnchors(
                    primaryAnchor: Offset(200, 200),
                  ),
                  buttonItems: [
                    ContextMenuButtonItem(
                      type: ContextMenuButtonType.copy,
                      onPressed: () => copies++,
                    ),
                  ],
                )
              : const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final copy = find.byKey(const ValueKey('folio_toolbar_copy'));
    expect(copy, findsOneWidget);
    shown.value = false;
    await tester.pump();
    await tester.pump();
    expect(copy, findsOneWidget);
    expect(
      tester.widget<ScaleReveal>(find.byType(ScaleReveal)).visible,
      isFalse,
    );
    await tester.tap(copy, warnIfMissed: false);
    expect(copies, 0);
    await tester.pumpAndSettle();
    expect(copy, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('menu recreation keeps one presentation and updated actions', (
    tester,
  ) async {
    final generation = ValueNotifier(0);
    addTearDown(generation.dispose);
    var copiedGeneration = -1;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => FolioSelectionToolbarHost(child: child!),
        home: ValueListenableBuilder<int>(
          valueListenable: generation,
          builder: (context, value, _) => FolioSelectionToolbar(
            key: ValueKey(value),
            anchors: TextSelectionToolbarAnchors(
              primaryAnchor: Offset(
                200 + 100 * value.toDouble(),
                200 + value.toDouble(),
              ),
            ),
            buttonItems: [
              ContextMenuButtonItem(
                type: ContextMenuButtonType.copy,
                onPressed: () => copiedGeneration = value,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    generation.value = 1;
    await tester.pump();
    await tester.pump();
    expect(find.byType(ScaleReveal), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('folio_toolbar_copy')));
    expect(copiedGeneration, 1);
    expect(
      tester.getCenter(find.byKey(const ValueKey('folio_toolbar_copy'))).dx,
      closeTo(300, 1),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
