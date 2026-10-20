import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/shared/selection/selection_visuals.dart';

void main() {
  test('selection contour rounds exposed line ends', () {
    final path = folioSelectionPath(const <Rect>[
      Rect.fromLTWH(10, 10, 100, 20),
      Rect.fromLTWH(10, 30, 60, 20),
    ]);
    expect(path.contains(const Offset(10, 10)), isFalse);
    expect(path.contains(const Offset(16, 16)), isTrue);
    expect(path.contains(const Offset(109, 20)), isTrue);
    expect(path.computeMetrics().length, 1);
  });

  test('adjacent lines form one shape across leading, with rounded steps', () {
    final path = folioSelectionPath(const <Rect>[
      Rect.fromLTWH(10, 10, 100, 20),
      Rect.fromLTWH(20, 34, 70, 20),
      Rect.fromLTWH(20, 58, 90, 20),
    ]);
    expect(path.computeMetrics().length, 1);
    expect(path.contains(const Offset(50, 32)), isTrue);
    expect(path.contains(const Offset(50, 56)), isTrue);
    expect(path.contains(const Offset(112, 45)), isFalse);
  });

  test('paragraph gaps and separated columns remain separate shapes', () {
    final path = folioSelectionPath(const <Rect>[
      Rect.fromLTWH(10, 10, 80, 20),
      Rect.fromLTWH(10, 60, 80, 20),
      Rect.fromLTWH(120, 10, 80, 20),
    ]);
    expect(path.computeMetrics().length, 3);
    expect(path.contains(const Offset(50, 43)), isFalse);
  });

  test('a heading joins the paragraph below it across the block gap', () {
    // Real line boxes: a 30 px heading, a 17 px body with 1.58 line height and
    // one 13 px block gap. The gap is wider than the old absolute 12 px cap, so
    // the heading used to fall out of the silhouette on its own.
    final path = folioSelectionPath(const <Rect>[
      Rect.fromLTWH(40, 40, 300, 35.4),
      Rect.fromLTWH(40.1, 88.4, 320, 26.86),
    ]);
    expect(path.computeMetrics().length, 1);
    expect(path.contains(const Offset(200, 80)), isTrue);
    expect(path.contains(const Offset(200, 120)), isFalse);
  });

  test('rows merge up to 65% of their mean line height and not beyond', () {
    Path select(double gap) => folioSelectionPath(<Rect>[
      Rect.fromLTWH(10, 10, 100, 20),
      Rect.fromLTWH(10, 30 + gap, 100, 20),
    ]);
    expect(select(13).computeMetrics().length, 1);
    expect(select(14).computeMetrics().length, 2);
  });

  test('glyph-tight heading boxes join the body below them', () {
    // Measured in the DOCX renderer: a heading whose glyph box is 22 px tall and
    // a 9 px body line, separated by an 8.6 px paragraph gap. The shorter row
    // allows only 5.9 px, which orphaned the heading in DOCX/PPTX and in PDF
    // text layers, where boxes follow the glyphs instead of the line box.
    final path = folioSelectionPath(const <Rect>[
      Rect.fromLTWH(40, 45.5, 112, 22),
      Rect.fromLTWH(40, 76.1, 227, 9),
    ]);
    expect(path.computeMetrics().length, 1);
    expect(path.contains(const Offset(100, 70)), isTrue);
    // One silhouette, still a staircase: the wider body does not widen the
    // heading's own line.
    expect(path.contains(const Offset(200, 70)), isFalse);
    expect(path.contains(const Offset(200, 72.5)), isTrue);
  });

  test('the mean rule keeps ordinary paragraph gaps apart', () {
    // Same renderer: the last line of a paragraph ends at 212.47 and the next
    // paragraph starts at 218.70 — a 6.23 px gap against a 5.85 px allowance.
    final path = folioSelectionPath(const <Rect>[
      Rect.fromLTWH(40, 203.47, 300, 9),
      Rect.fromLTWH(40, 218.70, 300, 9),
    ]);
    expect(path.computeMetrics().length, 2);
  });

  test('a list marker joins the text of its own line', () {
    // Measured in the markdown reader at 17 px / 1.58: the bullet box is
    // 24..41 and the paragraph starts at 49, an 8 px gap at a 26.9 px line. A
    // fixed 2 px allowance left every bullet alone, so consecutive bullets
    // merged into a separate vertical strip beside the text.
    final path = folioSelectionPath(const <Rect>[
      Rect.fromLTRB(49, 171.0, 354.1, 197.9),
      Rect.fromLTRB(24, 171.1, 41, 198.0),
    ]);
    expect(path.computeMetrics().length, 1);
    expect(path.contains(const Offset(30, 184)), isTrue);
    expect(path.contains(const Offset(200, 184)), isTrue);
    // The marker does not drag the line's right edge or the row above along.
    expect(path.contains(const Offset(24.5, 170)), isFalse);
  });

  test('table cells stay separate in the same line', () {
    // Measured header row: cells at 49..117, 159..261 and 286..388, separated
    // by 42 and 25 px of cell padding while the line is 26.9 px tall.
    final path = folioSelectionPath(const <Rect>[
      Rect.fromLTRB(49.4, 380.5, 117.2, 407.4),
      Rect.fromLTRB(159.2, 380.5, 260.9, 407.4),
      Rect.fromLTRB(285.8, 380.5, 387.5, 407.4),
    ]);
    expect(path.computeMetrics().length, 3);
    expect(path.contains(const Offset(140, 394)), isFalse);
    expect(path.contains(const Offset(270, 394)), isFalse);
  });

  test('same-line fragments merge up to half the row height and not beyond', () {
    Path select(double gap) => folioSelectionPath(<Rect>[
      Rect.fromLTWH(10, 10, 40, 20),
      Rect.fromLTWH(50 + gap, 10, 40, 20),
    ]);
    expect(select(10).computeMetrics().length, 1);
    expect(select(11).computeMetrics().length, 2);
  });

  test('input order does not change the silhouette', () {
    final boxes = <Rect>[
      const Rect.fromLTWH(10, 10, 100, 20),
      const Rect.fromLTWH(10, 30, 60, 20),
      const Rect.fromLTWH(20, 50, 90, 20),
      const Rect.fromLTWH(200, 10, 40, 20),
    ];
    final shapes = <int>{
      for (final order in <List<Rect>>[
        boxes,
        boxes.reversed.toList(),
        <Rect>[boxes[2], boxes[0], boxes[3], boxes[1]],
      ])
        folioSelectionPath(order).computeMetrics().length,
    };
    expect(shapes, <int>{2});
  });

  test('menu anchors stay near the current viewport after select all', () {
    final anchors = folioVisibleSelectionAnchors(
      original: const TextSelectionToolbarAnchors(
        primaryAnchor: Offset(20, -3000),
        secondaryAnchor: Offset(30, 8000),
      ),
      viewport: const Rect.fromLTWH(0, 0, 400, 800),
      visibleRects: const <Rect>[Rect.fromLTWH(42, 320, 250, 25)],
    );
    expect(anchors.primaryAnchor, const Offset(167, 320));
    expect(anchors.secondaryAnchor, const Offset(167, 345));
  });

  testWidgets('every selected line is actually painted', (tester) async {
    // Rect lists prove the geometry; this proves the silhouette reaches pixels.
    // A vanishing highlight is the failure users see, so assert on the raster.
    const size = Size(240, 60);
    const rects = <Rect>[
      Rect.fromLTWH(10, 10, 100, 20),
      Rect.fromLTWH(10, 30, 60, 20),
      Rect.fromLTWH(120, 10, 80, 20),
    ];
    final recorder = ui.PictureRecorder();
    FolioSelectionHighlightPainter(() => rects).paint(Canvas(recorder), size);
    final picture = recorder.endRecording();
    final pixels = await tester.runAsync(() async {
      final image = await picture.toImage(240, 60);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!.buffer.asUint8List();
    });
    int alphaAt(Offset point) =>
        pixels![(point.dy.round() * 240 + point.dx.round()) * 4 + 3];

    expect(alphaAt(const Offset(50, 20)), greaterThan(0));
    expect(alphaAt(const Offset(30, 40)), greaterThan(0));
    expect(alphaAt(const Offset(160, 20)), greaterThan(0));
    expect(alphaAt(const Offset(100, 40)), 0);
    expect(alphaAt(const Offset(20, 55)), 0);
  });
}
