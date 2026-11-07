import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/reader/data/document_content_source.dart';
import 'package:folio/features/reader/office/data/office_document_gateway.dart';
import 'package:folio/features/reader/office/widgets/office_document_platform_view.dart';
import 'package:folio/features/reader/powerpoint/logic/powerpoint_document_renderer.dart';
import 'package:folio/features/reader/powerpoint/widgets/powerpoint_document_view.dart';
import 'package:folio/features/reader/widgets/reader_chrome.dart';
import 'package:folio/features/reader/widgets/reader_screen.dart';
import 'package:folio/features/tutorial/logic/tutorial_controller.dart';
import 'package:folio/features/tutorial/tutorial_catalog.dart';
import 'package:folio/features/tutorial/widgets/tutorial_scope.dart';
import 'package:folio/features/tutorial/widgets/tutorial_swipe_up_cue.dart';
import 'package:folio/shared/glass/widgets/liquid_search_control.dart';
import 'package:folio/shared/widgets/info_notice/info_notice_tooltip.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../support/memory_tutorial_store.dart';

// Widget-side bridge contract. Browser tests separately exercise actual slide
// taps/swipes. A fake session avoids requiring an Android WebView here.
void main() {
  testWidgets('PPTX shows only a rising arrow until the overview opens', (
    tester,
  ) async {
    final store = MemoryTutorialStore();
    final tutorial = TutorialController(store: store);
    addTearDown(tutorial.dispose);
    await tutorial.load();
    final renderer = await _pumpReader(tester, tutorial: tutorial);

    final cue = find.byType(TutorialSwipeUpCue);
    final arrow = find.descendant(
      of: cue,
      matching: find.byIcon(LucideIcons.chevronUp),
    );
    expect(arrow, findsOneWidget);
    expect(find.byType(InfoNoticeTooltip), findsNothing);
    final initialY = tester.getCenter(arrow).dy;
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.getCenter(arrow).dy, lessThan(initialY));

    renderer.handleViewEvent(<Object?, Object?>{
      'type': 'overview',
      'open': true,
    });
    await tester.pumpAndSettle();
    expect(cue, findsNothing);
    expect(store.saved, {TutorialTour.pptxOverview});
  });

  testWidgets('PPTX controls toggle once per bridge centre tap', (
    tester,
  ) async {
    await _pumpReader(tester);
    _expectChrome(tester, visible: true);
    await _centreTap(tester);
    _expectChrome(tester, visible: false);
    await _centreTap(tester);
    _expectChrome(tester, visible: true);
  });

  testWidgets('PPTX does not subscribe to Office reading-scroll events', (
    tester,
  ) async {
    await _pumpReader(tester);
    final view = tester.widget<OfficeDocumentPlatformView>(
      find.byType(OfficeDocumentPlatformView),
    );
    expect(view.onReadingGesture, isNull);
  });

  testWidgets('scroll notifications cannot hide or reveal PPTX controls', (
    tester,
  ) async {
    await _pumpReader(tester);
    for (final visible in <bool>[true, false]) {
      if (!visible) await _centreTap(tester);
      for (final axis in <AxisDirection>[
        AxisDirection.right,
        AxisDirection.down,
      ]) {
        for (final delta in <double>[100, -100]) {
          _dispatchScroll(tester, axis, delta);
          await tester.pumpAndSettle();
          _expectChrome(tester, visible: visible);
        }
      }
    }
  });

  testWidgets('raw PPTX pointer taps cannot bypass the native tap classifier', (
    tester,
  ) async {
    await _pumpReader(tester);
    await _centreTap(tester);
    final rect = tester.getRect(
      find.byKey(const ValueKey<String>('reader_surface')),
    );
    for (final x in <double>[0.05, 0.5, 0.95]) {
      await tester.tapAt(Offset(rect.left + rect.width * x, rect.center.dy));
      await tester.pumpAndSettle();
      _expectChrome(tester, visible: false);
    }
    await _centreTap(tester);
    _expectChrome(tester, visible: true);
  });

  testWidgets('PPTX position updates keep visible and hidden controls stable', (
    tester,
  ) async {
    final renderer = await _pumpReader(tester);
    for (final visible in <bool>[true, false]) {
      if (!visible) await _centreTap(tester);
      for (final current in <int>[2, 3, 1]) {
        renderer.handleViewEvent(<Object?, Object?>{
          'type': 'position',
          'current': current,
          'count': 3,
        });
        await tester.pumpAndSettle();
        _expectChrome(tester, visible: visible);
      }
    }
  });

  testWidgets('centre taps do not close chrome while search is expanded', (
    tester,
  ) async {
    await _pumpReader(tester);
    tester
        .state<LiquidSearchControlState>(find.byType(LiquidSearchControl))
        .open();
    await tester.pumpAndSettle();
    await _centreTap(tester);
    _expectChrome(tester, visible: true);
  });

  testWidgets('PPTX overview pins the chrome hidden; closing restores it', (
    tester,
  ) async {
    final renderer = await _pumpReader(tester);
    renderer.handleViewEvent(<Object?, Object?>{
      'type': 'overview',
      'open': true,
    });
    await tester.pumpAndSettle();
    _expectChrome(tester, visible: false);

    renderer.handleViewEvent(<Object?, Object?>{
      'type': 'overview',
      'open': false,
    });
    await tester.pumpAndSettle();
    _expectChrome(tester, visible: true);
  });

  testWidgets('an expanded search cannot keep chrome above the overview', (
    tester,
  ) async {
    final renderer = await _pumpReader(tester);
    tester
        .state<LiquidSearchControlState>(find.byType(LiquidSearchControl))
        .open();
    await tester.pumpAndSettle();
    _expectChrome(tester, visible: true);
    renderer.handleViewEvent(<Object?, Object?>{
      'type': 'overview',
      'open': true,
    });
    await tester.pumpAndSettle();
    _expectChrome(tester, visible: false);
    renderer.handleViewEvent(<Object?, Object?>{
      'type': 'overview',
      'open': false,
    });
    await tester.pumpAndSettle();
    // The pre-overview state had the search expanded: it comes back.
    _expectChrome(tester, visible: true);
  });

  testWidgets('system Back closes the overview instead of leaving the reader', (
    tester,
  ) async {
    final renderer = await _pumpReader(tester);
    renderer.handleViewEvent(<Object?, Object?>{
      'type': 'overview',
      'open': true,
    });
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('reader_surface')),
      findsOneWidget,
    );
    // The close command went out; the flag stays with the bridge until the
    // `overview` event completes the round trip.
    expect(renderer.slideOverviewOpen, isTrue);
  });

  testWidgets('PPTX controls preserve visibility through a viewport rotation', (
    tester,
  ) async {
    await _pumpReader(tester);
    await _centreTap(tester);
    await tester.binding.setSurfaceSize(const Size(915, 412));
    await tester.pumpAndSettle();
    _expectChrome(tester, visible: false);
    await _centreTap(tester);
    await tester.binding.setSurfaceSize(const Size(412, 915));
    await tester.pumpAndSettle();
    _expectChrome(tester, visible: true);
  });
}

Future<PowerPointDocumentRenderer> _pumpReader(
  WidgetTester tester, {
  TutorialController? tutorial,
}) async {
  await tester.binding.setSurfaceSize(const Size(412, 915));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final document = DocumentEntry(
    id: '/slides.pptx',
    source: const FileDocumentSource('/slides.pptx'),
    name: 'Slides.pptx',
    format: DocumentFormat.pptx,
    sizeBytes: 2048,
    modifiedAt: DateTime.utc(2026, 9, 19),
  );
  final renderer = PowerPointDocumentRenderer(
    document: document,
    gateway: _Gateway(),
  );
  await renderer.open();
  renderer.handleViewEvent(<Object?, Object?>{
    'type': 'ready',
    'count': 3,
    'hasText': true,
  });
  final app = MaterialApp(
    home: ReaderScreen(
      document: document,
      contentSource: MemoryDocumentContentSource(<String, Uint8List>{}),
      initialRenderer: renderer,
      onRemoveFromRecents: () async {},
    ),
  );
  if (tutorial == null) {
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
  } else {
    await tester.pumpWidget(TutorialScope(controller: tutorial, child: app));
    await tester.pump();
  }
  // ReaderScreen owns/disposes the adopted renderer.
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  return renderer;
}

Future<void> _centreTap(WidgetTester tester) async {
  tester
      .widget<PowerPointDocumentView>(find.byType(PowerPointDocumentView))
      .onContentTap();
  await tester.pumpAndSettle();
}

void _expectChrome(WidgetTester tester, {required bool visible}) {
  for (final shell in tester.widgetList<ReaderChromeShell>(
    find.byType(ReaderChromeShell),
  )) {
    expect(shell.progress.value, visible ? 1 : 0);
  }
  expect(find.byType(ReaderChromeShell), findsWidgets);
}

void _dispatchScroll(
  WidgetTester tester,
  AxisDirection direction,
  double delta,
) {
  final context = tester.element(find.byType(PowerPointDocumentView));
  ScrollUpdateNotification(
    metrics: FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 2000,
      pixels: 400,
      viewportDimension: 412,
      axisDirection: direction,
      devicePixelRatio: 1,
    ),
    context: context,
    scrollDelta: delta,
    dragDetails: DragUpdateDetails(
      globalPosition: const Offset(200, 400),
      delta: direction == AxisDirection.right
          ? Offset(-delta, 0)
          : Offset(0, -delta),
    ),
  ).dispatch(context);
}

class _Gateway implements OfficeDocumentGateway {
  @override
  Future<OfficeDocumentSession> prepare(DocumentEntry document) async =>
      OfficeDocumentSession(
        id: 'pptx-chrome-test',
        format: document.format,
        sizeBytes: document.sizeBytes,
        close: () async {},
      );
}
