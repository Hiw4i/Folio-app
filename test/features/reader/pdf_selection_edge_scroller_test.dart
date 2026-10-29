import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/reader/pdf/logic/pdf_selection_edge_scroller.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  testWidgets(
    'PDF zoom keeps screen speed and selects the glyph under the handle',
    (tester) async {
      for (final zoom in [1.0, 2.0]) {
        final viewer = _Viewer();
        final pointer = Offset(20 * zoom, 390);
        viewer.value = Matrix4.diagonal3Values(zoom, zoom, 1)
          ..storage[13] = 390 - 420 * zoom;
        final initialTranslation = viewer.value.storage[13];
        final scroller = _scroller(tester, viewer);
        addTearDown(scroller.dispose);
        scroller.start(viewer.anchor, pointer);
        await tester.pump();
        await _advance(tester, 450);

        // 10 px into the bottom edge gives 900 logical screen px/s at either
        // scale: 405 px over 450 ms. The document distance halves at zoom 2.
        expect(
          initialTranslation - viewer.value.storage[13],
          closeTo(405, .001),
        );
        expect(viewer.currentZoom, zoom);
        expect(viewer.selection.range.start.index, 0);
        expect(viewer.selection.range.end.index, zoom == 1 ? 8 : 6);
        final selectedGlyph = viewer
            .text
            .charRects[viewer.selection.range.end.index]
            .toRectInDocument(
              page: viewer.pages.first,
              pageRect: viewer.layout.pageLayouts.first,
            );
        expect(
          selectedGlyph.contains(viewer.globalToDocument(pointer)!),
          isTrue,
        );
        scroller.stop();
      }
    },
  );

  testWidgets(
    'held PDF edge uses resized viewport bounds and stops in its center',
    (tester) async {
      final viewer = _Viewer();
      final scroller = _scroller(tester, viewer);
      addTearDown(scroller.dispose);
      scroller.start(viewer.anchor, const Offset(20, 390));
      await tester.pump();
      await _advance(tester, 100);
      viewer.viewportSize = const Size(600, 300);
      final beforeResize = viewer.value.storage[13];
      await _advance(tester, 400);
      // The stationary pointer is now beyond the shortened screen edge, so it
      // uses the full edge speed and its text hit test is clipped to y=300.
      expect(beforeResize - viewer.value.storage[13], closeTo(400, .001));
      // 90 px before resize + 400 px after it + clipped y=300 + initial
      // handle offset 30 gives document y=820, inside character 8.
      expect(viewer.selection.range.end.index, 8);
      viewer.viewportSize = const Size(300, 800);
      final beforeExpansion = viewer.value.storage[13];
      final selected = viewer.selection.range;
      await _advance(tester, 200);
      expect(viewer.value.storage[13], beforeExpansion);
      expect(viewer.selection.range, same(selected));
      expect(tester.binding.transientCallbackCount, 0);
      scroller.stop();
    },
  );

  testWidgets(
    'failed PDF text extraction preserves range without retrying each frame',
    (tester) async {
      final viewer = _Viewer()
        ..textFailure = StateError('Unreadable text layer');
      final selected = viewer.selection.range;
      final scroller = _scroller(tester, viewer);
      addTearDown(scroller.dispose);
      scroller.start(viewer.anchor, const Offset(20, 390));
      await tester.pump();
      await _advance(tester, 600);
      expect(viewer.loads, 1);
      expect(viewer.selection.range, same(selected));
      expect(viewer.value.storage[13], closeTo(-540, .001));
      expect(tester.takeException(), isNull);
      scroller.stop();

      // A later deliberate drag may retry, and resumes from the retained range.
      viewer.textFailure = null;
      scroller.start(viewer.anchor, const Offset(20, 390));
      await tester.pump();
      await _advance(tester, 200);
      expect(viewer.loads, 2);
      expect(viewer.selection.range.start.index, 0);
      expect(viewer.selection.range.end.index, greaterThan(4));
      scroller.stop();
    },
  );

  testWidgets('top PDF handle keeps its opposite endpoint while scrolling up', (
    tester,
  ) async {
    final viewer = _Viewer();
    viewer.value = Matrix4.identity()..storage[13] = -800;
    viewer.selection.range = PdfTextSelectionRange.fromPoints(
      PdfTextSelectionPoint(viewer.text, 12),
      PdfTextSelectionPoint(viewer.text, 19),
    );
    final scroller = _scroller(tester, viewer);
    addTearDown(scroller.dispose);
    scroller.start(
      PdfTextSelectionAnchor(
        const Rect.fromLTWH(10, 1210, 20, 20),
        PdfTextDirection.ltr,
        PdfTextSelectionAnchorType.a,
        viewer.text,
        12,
      ),
      const Offset(20, 20),
    );
    await tester.pump();
    await _advance(tester, 400);
    expect(viewer.value.storage[13], greaterThan(-800));
    expect(viewer.selection.range.start.index, lessThan(12));
    expect(viewer.selection.range.end.index, 19);
    scroller.stop();
  });

  testWidgets('PDF edge selection advances across page boundaries', (
    tester,
  ) async {
    final viewer = _TwoPageViewer();
    final scroller = _scroller(tester, viewer);
    addTearDown(scroller.dispose);
    scroller.start(viewer.anchor, const Offset(20, 390));
    await tester.pump();
    await _advance(tester, 2200);
    expect(viewer.selection.range.start.text.pageNumber, 1);
    expect(viewer.selection.range.start.index, 0);
    expect(viewer.selection.range.end.text.pageNumber, 2);
    expect(viewer.loads, 2);
    scroller.stop();
  });

  testWidgets('disposing an active PDF drag rejects pending text and frames', (
    tester,
  ) async {
    final viewer = _Viewer()..pendingText = Completer<PdfPageText>();
    final scroller = _scroller(tester, viewer);
    scroller.start(viewer.anchor, const Offset(20, 390));
    await tester.pump();
    await _advance(tester, 100);
    scroller.dispose();
    viewer.pendingText!.complete(viewer.text);
    final stopped = viewer.value.storage[13];
    await _advance(tester, 200);
    expect(viewer.value.storage[13], stopped);
    expect(viewer.selection.range.end.index, 4);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('held PDF handle scrolls and extends selection without moves', (
    tester,
  ) async {
    final viewer = _Viewer();
    final scroller = _scroller(tester, viewer);
    addTearDown(scroller.dispose);
    scroller.start(viewer.anchor, const Offset(20, 390));
    await tester.pump();
    await _advance(tester, 400);
    expect(viewer.value.storage[13], lessThan(-300));
    expect(viewer.selection.range.start.index, 0);
    expect(viewer.selection.range.end.index, greaterThan(4));
    expect(viewer.loads, 1);
    final before = viewer.selection.range.end.index;
    await _advance(tester, 200);
    expect(viewer.selection.range.end.index, greaterThan(before));
    scroller.stop();
  });

  testWidgets(
    'stopping a PDF drag prevents pending text from changing selection',
    (tester) async {
      final viewer = _Viewer()..pendingText = Completer<PdfPageText>();
      final scroller = _scroller(tester, viewer);
      addTearDown(scroller.dispose);
      scroller.start(viewer.anchor, const Offset(20, 390));
      await tester.pump();
      await _advance(tester, 100);
      expect(viewer.loads, 1);
      scroller.stop();
      final stopped = viewer.value.storage[13];
      viewer.pendingText!.complete(viewer.text);
      await _advance(tester, 200);
      expect(viewer.value.storage[13], stopped);
      expect(viewer.selection.range.end.index, 4);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'PDF selection survives manual viewport scrolling after release',
    (tester) async {
      final viewer = _Viewer();
      final scroller = _scroller(tester, viewer);
      addTearDown(scroller.dispose);
      scroller.start(viewer.anchor, const Offset(20, 390));
      await tester.pump();
      await _advance(tester, 100);
      scroller.stop();
      final selected = viewer.selection.range;
      viewer.value = Matrix4.copy(viewer.value)..storage[13] -= 100;
      await _advance(tester, 200);
      expect(viewer.selection.range, same(selected));
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets('leaving the PDF edge stops movement and document bounds clamp', (
    tester,
  ) async {
    final viewer = _Viewer();
    final scroller = _scroller(tester, viewer);
    addTearDown(scroller.dispose);
    scroller.start(viewer.anchor, const Offset(20, 390));
    await tester.pump();
    await _advance(tester, 100);
    scroller.update(const Offset(20, 200));
    final stopped = viewer.value.storage[13];
    await _advance(tester, 200);
    expect(viewer.value.storage[13], stopped);
    scroller.update(const Offset(20, 410));
    await tester.pump();
    await _advance(tester, 2500);
    expect(viewer.value.storage[13], -1600);
    expect(tester.binding.transientCallbackCount, 0);
  });
}

PdfSelectionEdgeScroller _scroller(
  WidgetTester tester,
  _Viewer viewer,
) => PdfSelectionEdgeScroller(
  vsync: tester,
  controller: viewer,
  viewport: () => viewer.viewportOrigin & viewer.viewSize,
  loadPageText: (page) {
    viewer.loads++;
    if (viewer.textFailure case final failure?) return Future.error(failure);
    return viewer.pendingText?.future ?? Future.value(viewer.textForPage(page));
  },
  onSelectionChanged: () {},
);

Future<void> _advance(WidgetTester tester, int milliseconds) async {
  for (var elapsed = 0; elapsed < milliseconds; elapsed += 10) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

class _Viewer implements PdfViewerController {
  _Viewer() {
    selection = _Selection(
      PdfTextSelectionRange.fromPoints(
        PdfTextSelectionPoint(text, 0),
        PdfTextSelectionPoint(text, 4),
      ),
    );
  }

  final text = PdfPageText(
    pageNumber: 1,
    fullText: 'abcdefghijklmnopqrst',
    charRects: List.generate(
      20,
      (i) => PdfRect(10, 1990.0 - i * 100, 30, 1970.0 - i * 100),
    ),
    fragments: const [],
  );
  late final _Selection selection;
  int loads = 0;
  Object? textFailure;
  Size viewportSize = const Size(300, 400);
  Offset viewportOrigin = Offset.zero;
  Completer<PdfPageText>? pendingText;
  PdfPageText textForPage(PdfPage page) => text;
  Matrix4 _value = Matrix4.identity();
  @override
  Matrix4 get value => _value;
  @override
  set value(Matrix4 next) {
    _value = next;
    final maxExtent = (documentSize.height * currentZoom - viewSize.height)
        .clamp(0.0, double.infinity);
    _value.storage[13] = _value.storage[13].clamp(-maxExtent, 0.0);
  }

  PdfTextSelectionAnchor get anchor => PdfTextSelectionAnchor(
    const Rect.fromLTWH(10, 410, 20, 20),
    PdfTextDirection.ltr,
    PdfTextSelectionAnchorType.b,
    text,
    4,
  );
  @override
  bool get isReady => true;
  @override
  Size get documentSize => const Size(300, 2000);
  @override
  Size get viewSize => viewportSize;
  @override
  double get currentZoom => value.getMaxScaleOnAxis();
  @override
  PdfPageLayout get layout => PdfPageLayout(
    pageLayouts: const [Rect.fromLTWH(0, 0, 300, 2000)],
    documentSize: documentSize,
  );
  @override
  List<PdfPage> get pages => const [_Page()];
  @override
  PdfTextSelectionDelegate get textSelectionDelegate => selection;
  @override
  Offset? globalToDocument(Offset global) => MatrixUtils.transformPoint(
    Matrix4.inverted(value),
    global - viewportOrigin,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Selection implements PdfTextSelectionDelegate {
  _Selection(this.range);
  PdfTextSelectionRange range;
  @override
  PdfTextSelectionRange get textSelectionPointRange => range;
  @override
  bool get hasSelectedText => true;
  @override
  Future<void> setTextSelectionPointRange(PdfTextSelectionRange value) async {
    range = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Page implements PdfPage {
  const _Page([this.pageNumber = 1]);
  @override
  final int pageNumber;
  @override
  double get width => 300;
  @override
  double get height => 2000;
  @override
  PdfPageRotation get rotation => PdfPageRotation.none;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TwoPageViewer extends _Viewer {
  @override
  PdfPageText textForPage(PdfPage page) => page.pageNumber == 1
      ? text
      : PdfPageText(
          pageNumber: 2,
          fullText: text.fullText,
          charRects: text.charRects,
          fragments: text.fragments,
        );
  @override
  Size get documentSize => const Size(300, 4000);
  @override
  List<PdfPage> get pages => const [_Page(), _Page(2)];
  @override
  PdfPageLayout get layout => PdfPageLayout(
    pageLayouts: const [
      Rect.fromLTWH(0, 0, 300, 2000),
      Rect.fromLTWH(0, 2000, 300, 2000),
    ],
    documentSize: documentSize,
  );
}
