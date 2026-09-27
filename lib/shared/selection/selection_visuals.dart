import 'package:flutter/widgets.dart';

import '../theme/folio_theme.dart';

/// The same highlight silhouette is used by the Flutter and PDF readers.
/// Office mirrors this radius in reader-selection.js.
const double folioSelectionCornerRadius = 6;
const Size folioSelectionMagnifierSize = Size(80, 40);

Path folioSelectionPath(Iterable<Rect> boxes) {
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
      if ((row.center.dy - box.center.dy).abs() <=
              (row.height < box.height ? row.height : box.height) * .35 &&
          box.left <= row.right + 2 &&
          box.right >= row.left - 2) {
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
      final gap = row.top - previous.bottom;
      final height = previous.height < row.height
          ? previous.height
          : row.height;
      if (gap >= -height * .35 &&
          gap <= (height * .65).clamp(2, 12) &&
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
    _addRoundedOutline(path, vertices);
  }
  return path;
}

void _addRoundedOutline(Path path, List<Offset> points) {
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
    final radius = folioSelectionCornerRadius
        .clamp(0, (a < b ? a : b) / 2)
        .toDouble();
    corners.add((
      before: vertex - incoming / a * radius,
      vertex: vertex,
      after: vertex + outgoing / b * radius,
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
