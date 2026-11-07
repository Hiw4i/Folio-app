import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../theme/app_spacing.dart';

/// Pure geometry in overlay coordinates, god_mode's InfoNoticeTooltip
/// layout. Kept separate from widgets so edge clamping, flipping and the
/// animation origin can be regression-tested.
@immutable
class InfoNoticeLayout {
  const InfoNoticeLayout({
    required this.rect,
    required this.anchor,
    required this.below,
    this.axis = Axis.vertical,
  });

  static const caretHeight = 8.0;
  static const gap = AppSpacing.xs;
  static const screenMargin = AppSpacing.lg;

  final Rect rect;
  final Offset anchor;

  /// Below on the vertical axis, right of the anchor on the horizontal axis.
  final bool below;
  final Axis axis;

  /// Deliberately not clamped to the straight part of the rounded edge: the
  /// caret's base can move away from a corner, but its tip must keep its target.
  double get pointerX => anchor.dx - rect.left;
  double get pointerY => anchor.dy - rect.top;

  EdgeInsets get caretPadding => axis == Axis.horizontal
      ? EdgeInsets.only(
          left: below ? caretHeight : 0,
          right: below ? 0 : caretHeight,
        )
      : EdgeInsets.only(
          top: below ? caretHeight : 0,
          bottom: below ? 0 : caretHeight,
        );

  /// Alignments outside [-1, 1] are valid. The target is outside the bubble,
  /// so clamping the alignment would move the scale origin off the target.
  Alignment get pivot => Alignment(
    2 * (anchor.dx - rect.left) / rect.width - 1,
    2 * (anchor.dy - rect.top) / rect.height - 1,
  );

  static Rect availableBounds(Rect viewport, Rect anchor) {
    // Collapse only the horizontal margin when the target itself is near an
    // edge. This keeps the tip inside the paint bounds without detaching it.
    final leftMargin = math.min(
      screenMargin,
      math.max(0.0, anchor.center.dx - viewport.left - 1),
    );
    final rightMargin = math.min(
      screenMargin,
      math.max(0.0, viewport.right - anchor.center.dx - 1),
    );
    final verticalMargin = math.min(screenMargin, viewport.height / 2);
    return Rect.fromLTRB(
      viewport.left + leftMargin,
      viewport.top + verticalMargin,
      viewport.right - rightMargin,
      viewport.bottom - verticalMargin,
    );
  }

  /// [desiredSize] includes content padding and the caret. Excessively tall
  /// content gets a bounded viewport; the widget makes only that text scroll.
  static InfoNoticeLayout? resolve({
    required Rect viewport,
    required Rect anchor,
    required Size desiredSize,
    bool preferBelow = true,
    Axis axis = Axis.vertical,
  }) {
    if (viewport.isEmpty ||
        anchor.isEmpty ||
        !viewport.contains(anchor.center)) {
      return null;
    }
    final bounds = availableBounds(viewport, anchor);
    if (axis == Axis.horizontal) {
      final rightSpace = math.max(0.0, bounds.right - anchor.right - gap);
      final leftSpace = math.max(0.0, anchor.left - gap - bounds.left);
      final fitsRight = desiredSize.width <= rightSpace;
      final fitsLeft = desiredSize.width <= leftSpace;
      final right = !fitsLeft && (fitsRight || rightSpace > leftSpace);
      final width = math.min(desiredSize.width, right ? rightSpace : leftSpace);
      final height = math.min(desiredSize.height, bounds.height);
      if (width <= caretHeight + AppSpacing.md * 2 || height <= 0) return null;
      final top = (anchor.center.dy - height / 2)
          .clamp(bounds.top, bounds.bottom - height)
          .toDouble();
      return InfoNoticeLayout(
        rect: Rect.fromLTWH(
          right ? anchor.right + gap : anchor.left - gap - width,
          top,
          width,
          height,
        ),
        anchor: anchor.center,
        below: right,
        axis: axis,
      );
    }
    final belowSpace = math.max(0.0, bounds.bottom - anchor.bottom - gap);
    final aboveSpace = math.max(0.0, anchor.top - gap - bounds.top);
    final fitsBelow = desiredSize.height <= belowSpace;
    final fitsAbove = desiredSize.height <= aboveSpace;
    final below = fitsBelow && fitsAbove
        ? preferBelow
        : fitsBelow || (!fitsAbove && belowSpace >= aboveSpace);
    final height = math.min(
      desiredSize.height,
      below ? belowSpace : aboveSpace,
    );
    final width = math.min(desiredSize.width, bounds.width);
    if (width <= 0 || height <= caretHeight + AppSpacing.md * 2) return null;

    final left = (anchor.center.dx - width / 2)
        .clamp(bounds.left, bounds.right - width)
        .toDouble();
    final top = below ? anchor.bottom + gap : anchor.top - gap - height;
    return InfoNoticeLayout(
      rect: Rect.fromLTWH(left, top, width, height),
      anchor: anchor.center,
      below: below,
    );
  }
}
