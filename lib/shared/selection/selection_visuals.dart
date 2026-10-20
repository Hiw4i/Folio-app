import 'package:flutter/widgets.dart';

import '../theme/folio_theme.dart';

/// The same highlight silhouette is used by the Flutter and PDF readers.
/// Office mirrors this radius in reader-selection.js.
const double folioSelectionCornerRadius = 6;

/// PDF fragments are glyph-tight, so their bars are barely taller than the
/// text and the full radius above turns every end into a pill. The smaller
/// radius keeps the same silhouette without looking rounder than in MD/TXT.
const double folioPdfSelectionCornerRadius = 4;
const Size folioSelectionMagnifierSize = Size(80, 40);

/// Rows this close horizontally belong to one visual line. The allowance is
/// half the shorter fragment's height with this floor, because a marker that
/// hangs in the indent is a whole word-space away from its text: the markdown
/// reader puts the bullet at 24..41 and the paragraph at 49 (an 8 px gap at a
/// 26.9 px line). A fixed 2 px allowance left the bullet alone, so the bullets
/// of consecutive items merged into their own vertical strip beside the text.
/// A share, not a constant, keeps table cells and columns apart: their gaps
/// equal a cell of padding (22..52 px in the same document).
const double _fragmentGapFloor = 2;
const double _fragmentGapShare = .5;

/// Two rows belong to one silhouette when they overlap by at most this share
/// of the shorter row's height...
const double _rowOverlap = .35;

/// ...or when the gap between them is at most this share of their mean height.
/// The share is relative on purpose: a heading and its body sit a paragraph gap
/// apart, and an absolute pixel cap used to orphan the heading from every
/// paragraph below it. The mean — not the shorter row — matters because a
/// heading is several times taller than a body line, and judging the gap by the
/// body alone kept the two apart in every renderer that reports glyph-tight
/// boxes (PDF text layers, DOM ranges).
const double _rowGap = .65;

/// Builds one rounded silhouette per contiguous run of selected lines.
///
/// Input rectangles are visual lines: their horizontal extent is the selected
/// run, their vertical extent is that line's box. Real line boxes (Flutter text)
/// and glyph-tight boxes (PDF text layers, DOM ranges) are both accepted: the
/// merge allowance is measured against the mean height of the two rows, so a
/// tall heading still joins the body below it either way.
Path folioSelectionPath(
  Iterable<Rect> boxes, {
  double radius = folioSelectionCornerRadius,
}) {
  final path = Path();
  final rows = <Rect>[];
  final sorted = boxes.where((r) => r.isFinite && !r.isEmpty).toList()
    ..sort((a, b) {
      final vertical = a.center.dy.compareTo(b.center.dy);
      return vertical != 0 ? vertical : a.left.compareTo(b.left);
    });
  // Glyph fragments from one visual line can arrive as separate DOM/PDF boxes.
  // Coalesce only touching fragments so columns and table cells stay distinct.
  for (final box in sorted) {
    var index = -1;
    for (var i = rows.length - 1; i >= 0; i--) {
      final row = rows[i];
      final height = _shorter(row.height, box.height);
      final allowance = _fragmentAllowance(height);
      if ((row.center.dy - box.center.dy).abs() <= height * _rowOverlap &&
          box.left <= row.right + allowance &&
          box.right >= row.left - allowance) {
        index = i;
        break;
      }
    }
    if (index < 0) {
      rows.add(box);
    } else {
      rows[index] = rows[index].expandToInclude(box);
    }
  }
  rows.sort((a, b) {
    final vertical = a.center.dy.compareTo(b.center.dy);
    return vertical != 0 ? vertical : a.left.compareTo(b.left);
  });
  final groups = <List<Rect>>[];
  for (final row in rows) {
    List<Rect>? owner;
    for (final group in groups.reversed) {
      final previous = group.last;
      final overlap = _shorter(previous.height, row.height);
      final gap = row.top - previous.bottom;
      if (gap >= -overlap * _rowOverlap &&
          gap <= (previous.height + row.height) / 2 * _rowGap &&
          row.left < previous.right &&
          row.right > previous.left) {
        owner = group;
        break;
      }
    }
    if (owner == null) {
      groups.add(<Rect>[row]);
    } else {
      owner.add(row);
    }
  }
  for (final group in groups) {
    final vertices = <Offset>[group.first.topLeft, group.first.topRight];
    for (var i = 1; i < group.length; i++) {
      final upper = group[i - 1], lower = group[i];
      final seam = (upper.bottom + lower.top) / 2;
      vertices.add(Offset(upper.right, seam));
      vertices.add(Offset(lower.right, seam));
    }
    vertices.add(group.last.bottomRight);
    vertices.add(group.last.bottomLeft);
    for (var i = group.length - 1; i > 0; i--) {
      final lower = group[i], upper = group[i - 1];
      final seam = (upper.bottom + lower.top) / 2;
      vertices.add(Offset(lower.left, seam));
      vertices.add(Offset(upper.left, seam));
    }
    _addRoundedOutline(path, vertices, radius);
  }
  return path;
}

double _shorter(double a, double b) => a < b ? a : b;

/// Horizontal reach for joining same-line fragments: a share of the shorter
/// fragment's height, never less than a couple of pixels for hairline boxes.
double _fragmentAllowance(double height) {
  final relative = height * _fragmentGapShare;
  return relative > _fragmentGapFloor ? relative : _fragmentGapFloor;
}

void _addRoundedOutline(Path path, List<Offset> points, double radius) {
  // A staircase is one filled silhouette. Round its inward as well as outward
  // corners; radius is capped by both adjacent segments to avoid loops.
  final corners = <({Offset before, Offset vertex, Offset after})>[];
  for (var i = 0; i < points.length; i++) {
    final previous = points[(i - 1 + points.length) % points.length];
    final vertex = points[i];
    final next = points[(i + 1) % points.length];
    final incoming = vertex - previous, outgoing = next - vertex;
    final a = incoming.distance, b = outgoing.distance;
    if (a == 0 || b == 0) continue;
    final cornerRadius = radius
        .clamp(0, (a < b ? a : b) / 2)
        .toDouble();
    corners.add((
      before: vertex - incoming / a * cornerRadius,
      vertex: vertex,
      after: vertex + outgoing / b * cornerRadius,
    ));
  }
  if (corners.isEmpty) return;
  path.moveTo(corners.first.before.dx, corners.first.before.dy);
  for (var i = 0; i < corners.length; i++) {
    final corner = corners[i];
    path.quadraticBezierTo(
      corner.vertex.dx,
      corner.vertex.dy,
      corner.after.dx,
      corner.after.dy,
    );
    final next = corners[(i + 1) % corners.length];
    path.lineTo(next.before.dx, next.before.dy);
  }
  path.close();
}

class FolioSelectionHighlightPainter extends CustomPainter {
  FolioSelectionHighlightPainter(this.visibleRects, {super.repaint});

  final List<Rect> Function() visibleRects;

  @override
  void paint(Canvas canvas, Size size) {
    final rects = visibleRects();
    if (rects.isEmpty) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawPath(
      folioSelectionPath(rects),
      Paint()..color = appColors.selection,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(FolioSelectionHighlightPainter oldDelegate) =>
      oldDelegate.visibleRects != visibleRects;
}

/// Place the action pill next to a visible line, even when the selection's
/// actual endpoints are many pages away. The input/output coordinate space is
/// the viewport supplied by the caller.
TextSelectionToolbarAnchors folioVisibleSelectionAnchors({
  required TextSelectionToolbarAnchors? original,
  required Rect viewport,
  required Iterable<Rect> visibleRects,
}) {
  final safe = viewport.deflate(12);
  Rect? candidate;
  for (final rect in visibleRects) {
    final clipped = rect.intersect(safe);
    if (!clipped.isEmpty && clipped.isFinite) {
      candidate = clipped;
      break;
    }
  }
  final point = candidate == null
      ? Offset(safe.center.dx, safe.top + 56)
      : Offset(candidate.center.dx, candidate.top);
  final below = candidate == null
      ? point.translate(0, 24)
      : Offset(candidate.center.dx, candidate.bottom);
  final existing = original?.primaryAnchor;
  final primary =
      existing != null && viewport.contains(existing) && candidate == null
      ? existing
      : point;
  final secondary = original?.secondaryAnchor;
  return TextSelectionToolbarAnchors(
    primaryAnchor: primary,
    secondaryAnchor:
        secondary != null && viewport.contains(secondary) && candidate == null
        ? secondary
        : below,
  );
}
