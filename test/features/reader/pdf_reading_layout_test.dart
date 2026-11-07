import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/reader/pdf/logic/pdf_reading_layout.dart';
import 'package:pdfrx/pdfrx.dart';

// Pure geometry/delegate tests: no PDFium or platform view is needed.
void main() {
  const params = PdfViewerParams(margin: 0);

  test('PDF column has no horizontal gutters and keeps vertical gaps', () {
    final layout = layoutPdfReadingPages(const <PdfPage>[
      _Page(612, 792),
      _Page(612, 792),
    ], params);
    expect(layout.pageLayouts, <Rect>[
      const Rect.fromLTWH(0, 12, 612, 792),
      const Rect.fromLTWH(0, 816, 612, 792),
    ]);
    expect(layout.documentSize, const Size(612, 1620));
  });

  test('mixed PDF page sizes share a width without changing aspect ratios', () {
    const pages = <PdfPage>[
      _Page(595.276, 841.89),
      _Page(792, 612),
      _Page(300, 600),
    ];
    final layout = layoutPdfReadingPages(pages, params);
    for (var i = 0; i < pages.length; i++) {
      final rect = layout.pageLayouts[i];
      expect(rect.left, 0);
      expect(rect.right, closeTo(layout.documentSize.width, 0.000001));
      expect(
        rect.width / rect.height,
        closeTo(pages[i].width / pages[i].height, 0.000001),
      );
    }
  });

  test('empty PDF layout is finite', () {
    final layout = layoutPdfReadingPages(const <PdfPage>[], params);
    expect(layout.pageLayouts, isEmpty);
    expect(layout.documentSize, Size.zero);
  });

  test('invalid provisional page dimensions do not poison the layout', () {
    final layout = layoutPdfReadingPages(const <PdfPage>[
      _Page(double.nan, 0),
      _Page(-1, double.infinity),
    ], params);
    expect(layout.documentSize, const Size(612, 1620));
    for (final rect in layout.pageLayouts) {
      expect(rect.isFinite, isTrue);
      expect(rect.width, greaterThan(0));
      expect(rect.height, greaterThan(0));
    }
  });

  for (final size in const <Size>[
    Size(360, 800),
    Size(412, 915),
    Size(800, 360),
    Size(915, 412),
    Size(1200, 800),
  ]) {
    test('initial PDF width fills ${size.width} x ${size.height}', () {
      final layout = layoutPdfReadingPages(const <PdfPage>[
        _Page(595.276, 841.89),
      ], params);
      final controller = _Controller(size);
      final delegate = pdfReadingSizeDelegateProvider.create()
        ..init(controller);
      addTearDown(delegate.dispose);
      final snapshot = _snapshot(delegate, layout, size);
      delegate.onLayoutInitialized(
        state: snapshot,
        initialPageNumber: 1,
        coverScale: snapshot.coverScale,
        alternativeFitScale: snapshot.alternativeFitScale,
        layout: layout,
        document: _Document(),
      );
      expect(
        layout.documentSize.width * controller.currentZoom,
        closeTo(size.width, 0.000001),
      );
    });
  }

  test('PDF fit-width follows repeated portrait and landscape rotation', () {
    final layout = layoutPdfReadingPages(const <PdfPage>[
      _Page(595.276, 841.89),
      _Page(595.276, 841.89),
    ], params);
    const portrait = Size(412, 915);
    final controller = _Controller(portrait);
    final delegate = pdfReadingSizeDelegateProvider.create()..init(controller);
    addTearDown(delegate.dispose);
    var previous = _snapshot(delegate, layout, portrait);
    controller.value = controller.calcMatrixFor(
      const Offset(297.638, 900),
      zoom: portrait.width / layout.documentSize.width,
    );
    for (final size in const <Size>[
      Size(915, 412),
      portrait,
      Size(915, 412),
      portrait,
    ]) {
      final next = _snapshot(delegate, layout, size);
      delegate.onLayoutUpdate(
        oldState: previous,
        newState: next,
        currentZoom: controller.currentZoom,
        oldVisibleRect: Rect.zero,
        anchorPageNumber: 1,
        isLayoutChanged: false,
        isViewSizeChanged: true,
      );
      expect(
        controller.currentZoom * layout.documentSize.width,
        closeTo(size.width, 0.000001),
      );
      expect(controller.lastCenter!.dx, closeTo(297.638, 0.000001));
      expect(controller.lastCenter!.dy, closeTo(900, 0.000001));
      previous = next;
    }
  });

  test('rotation does not reset a manually enlarged PDF', () {
    final layout = layoutPdfReadingPages(const <PdfPage>[
      _Page(612, 792),
    ], params);
    const portrait = Size(412, 915);
    final controller = _Controller(portrait);
    final delegate = pdfReadingSizeDelegateProvider.create()..init(controller);
    addTearDown(delegate.dispose);
    controller.value = controller.calcMatrixFor(
      const Offset(350, 400),
      zoom: 3,
    );
    delegate.onLayoutUpdate(
      oldState: _snapshot(delegate, layout, portrait),
      newState: _snapshot(delegate, layout, const Size(915, 412)),
      currentZoom: 3,
      oldVisibleRect: Rect.zero,
      anchorPageNumber: 1,
      isLayoutChanged: false,
      isViewSizeChanged: true,
    );
    expect(controller.currentZoom, 3);
    expect(controller.lastCenter!.dx, closeTo(350, 0.000001));
    expect(controller.lastCenter!.dy, closeTo(400, 0.000001));
  });
}

PdfViewerLayoutSnapshot _snapshot(
  PdfViewerSizeDelegate delegate,
  PdfPageLayout layout,
  Size size,
) {
  final metrics = delegate.calculateMetrics(
    viewSize: size,
    layout: layout,
    pageNumber: 1,
    pageMargin: 0,
    boundaryMargin: null,
  );
  return PdfViewerLayoutSnapshot(
    viewSize: size,
    layout: layout,
    minScale: metrics.minScale,
    coverScale: metrics.coverScale,
    alternativeFitScale: metrics.alternativeFitScale,
  );
}

class _Page implements PdfPage {
  const _Page(this.width, this.height);
  @override
  final double width;
  @override
  final double height;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Document implements PdfDocument {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Record the real pdfrx delegate's camera decisions without a native viewer.
class _Controller extends PdfViewerController {
  _Controller(this._viewSize);
  Size _viewSize;
  Matrix4 _matrix = Matrix4.identity();
  Offset? lastCenter;

  @override
  Matrix4 get value => _matrix;
  @override
  set value(Matrix4 matrix) => _matrix = matrix;
  @override
  double get currentZoom => _matrix.entry(0, 0);
  @override
  Size get viewSize => _viewSize;

  @override
  Matrix4 calcMatrixFor(Offset position, {double? zoom, Size? viewSize}) {
    lastCenter = position;
    final size = viewSize ?? _viewSize;
    _viewSize = size;
    final scale = zoom ?? currentZoom;
    return Matrix4.diagonal3Values(scale, scale, scale)..setTranslationRaw(
      size.width / 2 - position.dx * scale,
      size.height / 2 - position.dy * scale,
      0,
    );
  }

  @override
  Future<void> setZoom(
    Offset position,
    double zoom, {
    Duration duration = const Duration(milliseconds: 200),
  }) async {
    value = calcMatrixFor(position, zoom: zoom);
  }

  @override
  void stopInteractiveViewerAnimation() {}
}
