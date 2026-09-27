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
}
