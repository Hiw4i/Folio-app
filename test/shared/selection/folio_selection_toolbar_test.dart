import 'package:flutter/material.dart' show DefaultMaterialLocalizations;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/shared/selection/folio_selection_toolbar.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

void main() {
  testWidgets('continuously updating anchors do not freeze the pill', (
    tester,
  ) async {
    final anchors = ValueNotifier<double>(300);
    addTearDown(anchors.dispose);
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFF000000),
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          DefaultMaterialLocalizations.delegate,
        ],
        supportedLocales: const <Locale>[Locale('en')],
        pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
        ),
        home: ValueListenableBuilder<double>(
          valueListenable: anchors,
          builder: (context, y, child) => FolioSelectionToolbar(
            anchors: TextSelectionToolbarAnchors(primaryAnchor: Offset(200, y)),
            buttonItems: <ContextMenuButtonItem>[
              ContextMenuButtonItem(
                type: ContextMenuButtonType.copy,
                onPressed: () {},
              ),
              ContextMenuButtonItem(
                type: ContextMenuButtonType.selectAll,
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final pill = find.byWidgetPredicate(
      (widget) =>
          widget is SizedBox && widget.width == 89 && widget.height == 44,
    );
    final before = tester.getTopLeft(pill);
    for (var frame = 1; frame <= 20; frame++) {
      anchors.value = 300 - 5.0 * frame;
      await tester.pump(const Duration(milliseconds: 16));
    }
    final during = tester.getTopLeft(pill);
    await tester.pumpAndSettle();
    expect(
      during.dy,
      lessThan(before.dy - 30),
      reason:
          'automatic pill placement must progress while anchors keep moving',
    );
  });

  Future<void> pumpToolbar(
    WidgetTester tester,
    List<ContextMenuButtonItem> buttonItems, {
    TextSelectionToolbarAnchors anchors = const TextSelectionToolbarAnchors(
      primaryAnchor: Offset(100, 200),
    ),
    MediaQueryData? mediaQuery,
    Object? selectionId,
    FolioSelectionToolbarController? controller,
    bool settle = true,
  }) async {
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFF000000),
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          DefaultMaterialLocalizations.delegate,
        ],
        supportedLocales: const <Locale>[Locale('en')],
        pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
        ),
        home: MediaQuery(
          data: mediaQuery ?? MediaQueryData.fromView(tester.view),
          child: FolioSelectionToolbar(
            anchors: anchors,
            buttonItems: buttonItems,
            selectionId: selectionId,
            controller: controller,
          ),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  Finder pill() => find.byWidgetPredicate(
    (widget) => widget is SizedBox && widget.width == 89 && widget.height == 44,
  );

  List<ContextMenuButtonItem> readerActions({VoidCallback? onCopy}) =>
      <ContextMenuButtonItem>[
        ContextMenuButtonItem(
          onPressed: onCopy ?? () {},
          type: ContextMenuButtonType.copy,
        ),
        ContextMenuButtonItem(
          onPressed: () {},
          type: ContextMenuButtonType.selectAll,
        ),
      ];

  testWidgets('scrolling selection does not move the pill horizontally', (
    tester,
  ) async {
    final actions = readerActions();
    await pumpToolbar(
      tester,
      actions,
      anchors: const TextSelectionToolbarAnchors(
        primaryAnchor: Offset(180, 200),
        secondaryAnchor: Offset(520, 240),
      ),
    );
    final initialX = tester.getRect(pill()).center.dx;

    // A different line becomes the first visible selected line, and the menu
    // no longer fits above it. Neither transition should choose a new x.
    await pumpToolbar(
      tester,
      actions,
      anchors: const TextSelectionToolbarAnchors(
        primaryAnchor: Offset(510, 20),
        secondaryAnchor: Offset(510, 60),
      ),
    );

    expect(tester.getRect(pill()).center.dx, initialX);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolling an above pill up docks it calmly at the safe top', (
    tester,
  ) async {
    final actions = readerActions();
    var previousTop = double.infinity;
    for (final sample in <({double anchorY, double expectedTop})>[
      (anchorY: 200, expectedTop: 148),
      (anchorY: 140, expectedTop: 88),
      (anchorY: 84, expectedTop: 32),
      (anchorY: 80, expectedTop: 32),
      (anchorY: 40, expectedTop: 32),
      (anchorY: -120, expectedTop: 32),
    ]) {
      await pumpToolbar(
        tester,
        actions,
        anchors: TextSelectionToolbarAnchors(
          primaryAnchor: Offset(
            sample.anchorY == 200 ? 180 : 510,
            sample.anchorY,
          ),
          secondaryAnchor: Offset(520, sample.anchorY + 40),
        ),
        mediaQuery: const MediaQueryData(
          size: Size(800, 600),
          padding: EdgeInsets.only(top: 24),
        ),
      );

      final rect = tester.getRect(pill());
      expect(rect.top, sample.expectedTop);
      expect(rect.top, lessThanOrEqualTo(previousTop));
      expect(rect.center.dx, 180);
      previousTop = rect.top;
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('the initial below preference resets only for a new selection', (
    tester,
  ) async {
    final actions = readerActions();
    final controller = FolioSelectionToolbarController();
    await pumpToolbar(
      tester,
      actions,
      controller: controller,
      selectionId: 1,
      anchors: const TextSelectionToolbarAnchors(
        primaryAnchor: Offset(180, 20),
        secondaryAnchor: Offset(180, 40),
      ),
    );
    expect(tester.getRect(pill()).top, 60);

    await pumpToolbar(
      tester,
      actions,
      controller: controller,
      selectionId: 1,
      anchors: const TextSelectionToolbarAnchors(
        primaryAnchor: Offset(180, 200),
        secondaryAnchor: Offset(180, 240),
      ),
    );
    expect(tester.getRect(pill()).top, 260);

    await pumpToolbar(
      tester,
      actions,
      controller: controller,
      selectionId: 2,
      anchors: const TextSelectionToolbarAnchors(
        primaryAnchor: Offset(180, 200),
        secondaryAnchor: Offset(180, 240),
      ),
    );
    expect(tester.getRect(pill()).top, 148);
    expect(tester.takeException(), isNull);
  });

  testWidgets('top and bottom docking suppress subpixel anchor jitter', (
    tester,
  ) async {
    final actions = readerActions();
    for (final anchorY in <double>[200, 84.4, 83.6, 84.2]) {
      await pumpToolbar(
        tester,
        actions,
        anchors: TextSelectionToolbarAnchors(
          primaryAnchor: Offset(180, anchorY),
        ),
        mediaQuery: const MediaQueryData(
          size: Size(800, 600),
          padding: EdgeInsets.only(top: 24, bottom: 18),
        ),
      );
      if (anchorY != 200) expect(tester.getRect(pill()).top, 32);
    }
    for (final anchorY in <double>[581.6, 582.4, 581.8, 900]) {
      await pumpToolbar(
        tester,
        actions,
        anchors: TextSelectionToolbarAnchors(
          primaryAnchor: Offset(180, anchorY),
        ),
        mediaQuery: const MediaQueryData(
          size: Size(800, 600),
          padding: EdgeInsets.only(top: 24, bottom: 18),
        ),
      );
      expect(tester.getRect(pill()).bottom, 574);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('the initial above preference survives restoring the menu', (
    tester,
  ) async {
    final actions = readerActions();
    final controller = FolioSelectionToolbarController();
    await pumpToolbar(tester, actions, controller: controller, selectionId: 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpToolbar(
      tester,
      actions,
      controller: controller,
      selectionId: 1,
      anchors: const TextSelectionToolbarAnchors(
        primaryAnchor: Offset(100, 20),
        secondaryAnchor: Offset(100, 40),
      ),
    );

    expect(tester.getRect(pill()).top, 8);
    expect(tester.takeException(), isNull);
  });

  testWidgets('immediate dragging pins the pill without activating an icon', (
    tester,
  ) async {
    var copies = 0;
    final actions = readerActions(onCopy: () => copies++);
    await pumpToolbar(tester, actions);
    final before = tester.getRect(pill());
    final gesture = await tester.startGesture(
      tester.getCenter(find.bySemanticsLabel('Copy')),
    );
    await gesture.moveBy(const Offset(180, 130));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final moved = tester.getRect(pill());
    expect(moved.topLeft, before.topLeft + const Offset(180, 130));
    expect(copies, 0);

    await pumpToolbar(
      tester,
      actions,
      anchors: const TextSelectionToolbarAnchors(
        primaryAnchor: Offset(650, 500),
        secondaryAnchor: Offset(650, 550),
      ),
    );
    expect(tester.getRect(pill()), moved);

    await tester.tap(find.bySemanticsLabel('Copy'));
    await tester.pumpAndSettle();
    expect(copies, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('anchor movement animates the actual layout and hit target', (
    tester,
  ) async {
    var copies = 0;
    final actions = readerActions(onCopy: () => copies++);
    await pumpToolbar(tester, actions);
    final before = tester.getRect(pill());

    await pumpToolbar(
      tester,
      actions,
      anchors: const TextSelectionToolbarAnchors(
        primaryAnchor: Offset(100, 400),
      ),
      settle: false,
    );
    expect(tester.getRect(pill()), before);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final moving = tester.getRect(pill());
    expect(moving.top, greaterThan(before.top));
    expect(moving.top, lessThan(348));
    await tester.tapAt(tester.getCenter(find.bySemanticsLabel('Copy')));
    expect(copies, 1);
    await tester.pumpAndSettle();
    expect(tester.getRect(pill()).top, 348);
    expect(tester.takeException(), isNull);
  });

  testWidgets('continuous dragging follows every pointer frame without lag', (
    tester,
  ) async {
    await pumpToolbar(tester, readerActions());
    final before = tester.getRect(pill());
    final gesture = await tester.startGesture(tester.getCenter(pill()));
    for (var frame = 1; frame <= 8; frame++) {
      await gesture.moveBy(const Offset(24, 12));
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.getRect(pill()).topLeft,
        before.topLeft + Offset(24.0 * frame, 12.0 * frame),
      );
    }
    final released = tester.getRect(pill());
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getRect(pill()), released);
  });
  testWidgets('off-screen anchors keep actions above the keyboard and insets', (
    tester,
  ) async {
    await pumpToolbar(
      tester,
      readerActions(),
      anchors: const TextSelectionToolbarAnchors(
        primaryAnchor: Offset(-100, -400),
        secondaryAnchor: Offset(-100, 900),
      ),
      mediaQuery: const MediaQueryData(
        size: Size(800, 600),
        padding: EdgeInsets.fromLTRB(30, 24, 20, 18),
        viewInsets: EdgeInsets.only(bottom: 250),
      ),
    );

    final rect = tester.getRect(pill());
    expect(rect.left, greaterThanOrEqualTo(38));
    expect(rect.top, greaterThanOrEqualTo(32));
    expect(rect.right, lessThanOrEqualTo(772));
    expect(rect.bottom, lessThanOrEqualTo(342));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a dragged pill remains reachable after the viewport rotates', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final actions = readerActions();
    await pumpToolbar(tester, actions);
    final gesture = await tester.startGesture(tester.getCenter(pill()));
    await gesture.moveBy(const Offset(150, 500));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    final beforeRotation = tester.getRect(pill());
    expect(beforeRotation.top, greaterThan(500));

    tester.view.physicalSize = const Size(800, 400);
    await pumpToolbar(
      tester,
      actions,
      mediaQuery: const MediaQueryData(
        size: Size(800, 400),
        padding: EdgeInsets.fromLTRB(30, 24, 20, 18),
      ),
    );

    final rotated = tester.getRect(pill());
    expect(rotated.left, beforeRotation.left);
    expect(rotated.top, greaterThanOrEqualTo(32));
    expect(rotated.bottom, lessThanOrEqualTo(374));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a pin survives hiding and restoring the same selection menu', (
    tester,
  ) async {
    final controller = FolioSelectionToolbarController();
    final actions = readerActions();
    await pumpToolbar(tester, actions, controller: controller, selectionId: 1);
    final gesture = await tester.startGesture(tester.getCenter(pill()));
    await gesture.moveBy(const Offset(200, 160));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    final pinned = tester.getRect(pill());

    await tester.pumpWidget(const SizedBox.shrink());
    await pumpToolbar(
      tester,
      actions,
      controller: controller,
      selectionId: 1,
      anchors: const TextSelectionToolbarAnchors(
        primaryAnchor: Offset(650, 500),
      ),
    );

    expect(tester.getRect(pill()), pinned);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new selection resets the pin and captures its own anchor', (
    tester,
  ) async {
    final controller = FolioSelectionToolbarController();
    final actions = readerActions();
    await pumpToolbar(tester, actions, controller: controller, selectionId: 1);
    final gesture = await tester.startGesture(tester.getCenter(pill()));
    await gesture.moveBy(const Offset(180, 100));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    await pumpToolbar(
      tester,
      actions,
      controller: controller,
      selectionId: 2,
      anchors: const TextSelectionToolbarAnchors(
        primaryAnchor: Offset(650, 500),
      ),
    );

    expect(tester.getRect(pill()).center.dx, 650);
    expect(tester.getRect(pill()).top, 448);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dragging is clamped at every safe edge', (tester) async {
    await pumpToolbar(
      tester,
      readerActions(),
      mediaQuery: const MediaQueryData(
        size: Size(800, 600),
        padding: EdgeInsets.fromLTRB(30, 24, 20, 18),
        viewInsets: EdgeInsets.only(bottom: 250),
      ),
    );
    final gesture = await tester.startGesture(tester.getCenter(pill()));
    await gesture.moveBy(const Offset(-1000, -1000));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(pill()).topLeft, const Offset(38, 32));

    await gesture.moveBy(const Offset(3000, 3000));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(pill()).bottomRight, const Offset(772, 342));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getRect(pill()).bottomRight, const Offset(772, 342));
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows copy and select-all as lucide icons without text', (
    tester,
  ) async {
    await pumpToolbar(tester, <ContextMenuButtonItem>[
      ContextMenuButtonItem(onPressed: () {}, type: ContextMenuButtonType.copy),
      ContextMenuButtonItem(
        onPressed: () {},
        type: ContextMenuButtonType.selectAll,
      ),
    ]);
    await tester.pump();

    expect(find.byIcon(LucideIcons.copy), findsOneWidget);
    expect(find.byIcon(LucideIcons.textSelect), findsOneWidget);
    expect(find.text('Copy'), findsNothing);
    expect(find.text('Select all'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('filters out unrelated system actions', (tester) async {
    await pumpToolbar(tester, <ContextMenuButtonItem>[
      ContextMenuButtonItem(onPressed: () {}, type: ContextMenuButtonType.cut),
      ContextMenuButtonItem(onPressed: () {}, type: ContextMenuButtonType.copy),
      ContextMenuButtonItem(
        onPressed: () {},
        type: ContextMenuButtonType.paste,
      ),
      ContextMenuButtonItem(
        onPressed: () {},
        type: ContextMenuButtonType.share,
      ),
    ]);
    await tester.pump();

    expect(find.byIcon(LucideIcons.copy), findsOneWidget);
    expect(find.byIcon(LucideIcons.textSelect), findsNothing);
    expect(find.text('Cut'), findsNothing);
    expect(find.text('Paste'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders nothing without copy or select-all', (tester) async {
    await pumpToolbar(tester, <ContextMenuButtonItem>[
      ContextMenuButtonItem(
        onPressed: () {},
        type: ContextMenuButtonType.share,
      ),
    ]);
    await tester.pump();

    expect(find.byIcon(LucideIcons.copy), findsNothing);
    expect(find.byIcon(LucideIcons.textSelect), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the copy icon invokes its action', (tester) async {
    var activations = 0;
    await pumpToolbar(tester, <ContextMenuButtonItem>[
      ContextMenuButtonItem(
        onPressed: () => activations += 1,
        type: ContextMenuButtonType.copy,
      ),
      ContextMenuButtonItem(
        onPressed: () {},
        type: ContextMenuButtonType.selectAll,
      ),
    ]);
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Copy'));
    await tester.pumpAndSettle();

    expect(activations, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the select-all icon invokes its action', (tester) async {
    var activations = 0;
    await pumpToolbar(tester, <ContextMenuButtonItem>[
      ContextMenuButtonItem(onPressed: () {}, type: ContextMenuButtonType.copy),
      ContextMenuButtonItem(
        onPressed: () => activations += 1,
        type: ContextMenuButtonType.selectAll,
      ),
    ]);
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Select all'));
    await tester.pumpAndSettle();

    expect(activations, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pill surface keeps full painted size (icons stay inside)', (
    tester,
  ) async {
    await pumpToolbar(tester, <ContextMenuButtonItem>[
      ContextMenuButtonItem(onPressed: () {}, type: ContextMenuButtonType.copy),
      ContextMenuButtonItem(
        onPressed: () {},
        type: ContextMenuButtonType.selectAll,
      ),
    ]);
    await tester.pump();

    // Пилюля: 2 кнопки 36 + разделитель 9 + паддинги 2x4 = 89x44,
    // живописный бокс единой поверхности — плюс paintPadding (40)
    // с каждой стороны, как у остальных liquid-контролов.
    // Без OverflowBox внутренний бокс схлопывается до 89x44 и стеклянный
    // path съезжает относительно иконок.
    const pillWidth = 4.0 * 2 + 36.0 * 2 + 9.0;
    const expectedSurface = Size(pillWidth + 40 * 2, 44 + 40 * 2);
    final surfaces = find.byWidgetPredicate(
      (widget) => widget is SizedBox && widget.width == expectedSurface.width,
    );
    expect(surfaces, findsOneWidget);
    expect(tester.getSize(surfaces), expectedSurface);

    // Иконки лежат внутри пилюли, на одной горизонтали, copy слева.
    final pills = find.byWidgetPredicate(
      (widget) =>
          widget is SizedBox &&
          widget.width == pillWidth &&
          widget.height == 44,
    );
    expect(pills, findsOneWidget);
    final pillRect = tester.getRect(pills);
    final copyRect = tester.getRect(
      find.byKey(const ValueKey<String>('folio_toolbar_copy')),
    );
    final selectAllRect = tester.getRect(
      find.byKey(const ValueKey<String>('folio_toolbar_select_all')),
    );
    expect(
      copyRect.center.dy,
      moreOrLessEquals(pillRect.center.dy, epsilon: 1),
    );
    expect(
      selectAllRect.center.dy,
      moreOrLessEquals(pillRect.center.dy, epsilon: 1),
    );
    expect(copyRect.center.dx, lessThan(selectAllRect.center.dx));
    expect(
      (copyRect.center.dx + selectAllRect.center.dx) / 2,
      moreOrLessEquals(pillRect.center.dx, epsilon: 1),
    );
    expect(tester.takeException(), isNull);
  });
}
