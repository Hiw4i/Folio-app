import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart';

import 'info_notice_layout.dart';

/// One closed outline for both fill/blur clipping and border painting,
/// god_mode's InfoNoticeTooltip silhouette. Curved shoulders merge the caret
/// into the body without a seam or a second translucent layer. Only the base
/// is clamped around the rounded corners.
class InfoNoticeShape extends OutlinedBorder {
  const InfoNoticeShape({
    required this.pointerX,
    required this.below,
    this.pointerY,
    this.borderRadius = 24,
    super.side,
  });

  final double pointerX;
  final bool below;
  final double? pointerY;

  /// god_mode's sheet radius — the bubble rounding the caret shape was
  /// designed against.
  final double borderRadius;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  @override
  InfoNoticeShape copyWith({BorderSide? side}) => InfoNoticeShape(
    pointerX: pointerX,
    below: below,
    pointerY: pointerY,
    borderRadius: borderRadius,
    side: side ?? this.side,
  );

  @override
  InfoNoticeShape scale(double t) => copyWith(side: side.scale(t));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    if (rect.isEmpty) return Path();
    if (pointerY != null) {
      // Transpose the same silhouette, keeping its curved caret and border.
      return InfoNoticeShape(
            pointerX: pointerY!,
            below: below,
            borderRadius: borderRadius,
          )
          .getOuterPath(Rect.fromLTWH(0, 0, rect.height, rect.width))
          .transform(
            Float64List.fromList([
              0,
              1,
              0,
              0,
              1,
              0,
              0,
              0,
              0,
              0,
              1,
              0,
              rect.left,
              rect.top,
              0,
              1,
            ]),
          );
    }
    final caret = math.min(InfoNoticeLayout.caretHeight, rect.height);
    final body = Rect.fromLTRB(
      rect.left,
      rect.top + caret,
      rect.right,
      rect.bottom,
    );
    final halfBase = math.min(10.0, rect.width / 4);
    final radius = math.min(
      borderRadius,
      math.min(body.height / 2, (rect.width - 2 * halfBase) / 2),
    );
    final tip = (rect.left + pointerX).clamp(rect.left, rect.right).toDouble();
    final base = tip
        .clamp(body.left + radius + halfBase, body.right - radius - halfBase)
        .toDouble();
    final shoulder = halfBase * 0.55;
    final tipRound = math.min(1.0, math.min(tip - rect.left, rect.right - tip));
    final corner = Radius.circular(radius);
    final path = Path()
      ..moveTo(body.left + radius, body.top)
      ..lineTo(base - halfBase, body.top)
      ..cubicTo(
        base - halfBase + shoulder,
        body.top,
        math.max(rect.left, tip - tipRound * 2),
        rect.top + 2,
        tip - tipRound,
        rect.top + 1,
      )
      ..quadraticBezierTo(tip, rect.top - 1, tip + tipRound, rect.top + 1)
      ..cubicTo(
        math.min(rect.right, tip + tipRound * 2),
        rect.top + 2,
        base + halfBase - shoulder,
        body.top,
        base + halfBase,
        body.top,
      )
      ..lineTo(body.right - radius, body.top)
      ..arcToPoint(Offset(body.right, body.top + radius), radius: corner)
      ..lineTo(body.right, body.bottom - radius)
      ..arcToPoint(Offset(body.right - radius, body.bottom), radius: corner)
      ..lineTo(body.left + radius, body.bottom)
      ..arcToPoint(Offset(body.left, body.bottom - radius), radius: corner)
      ..lineTo(body.left, body.top + radius)
      ..arcToPoint(Offset(body.left + radius, body.top), radius: corner)
      ..close();
    if (below) return path;
    return path.transform(
      Float64List.fromList([
        1,
        0,
        0,
        0,
        0,
        -1,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        rect.top + rect.bottom,
        0,
        1,
      ]),
    );
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      InfoNoticeShape(
        pointerX: pointerX - side.width,
        below: below,
        pointerY: pointerY == null ? null : pointerY! - side.width,
        borderRadius: borderRadius,
      ).getOuterPath(rect.deflate(side.width), textDirection: textDirection);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width == 0) return;
    final path = getOuterPath(rect, textDirection: textDirection);
    // Keep the entire stroke inside the same silhouette used for clipping.
    canvas.save();
    canvas.clipPath(path);
    canvas.drawPath(path, side.toPaint()..strokeWidth = side.width * 2);
    canvas.restore();
  }

  @override
  bool operator ==(Object other) =>
      other is InfoNoticeShape &&
      other.pointerX == pointerX &&
      other.below == below &&
      other.pointerY == pointerY &&
      other.borderRadius == borderRadius &&
      other.side == side;

  @override
  int get hashCode =>
      Object.hash(pointerX, pointerY, below, borderRadius, side);
}
