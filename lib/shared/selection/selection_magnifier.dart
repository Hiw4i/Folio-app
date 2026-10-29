import 'package:flutter/material.dart' show Magnifier, TextMagnifier;
import 'package:flutter/widgets.dart';

import 'selection_visuals.dart';

/// Keep MD's platform positioning, animation, and iOS behavior intact. Material
/// constructor defaults also supply the PDF lens's tint, shadow, and clipping.
TextMagnifierConfiguration get folioTextMagnifierConfiguration =>
    TextMagnifier.adaptiveMagnifierConfiguration;

/// A PDF source crop that produces the same 1.25x screen magnification as MD,
/// independent of PDF font size and the reader's current zoom.
Rect folioSelectionMagnifierSourceRect({
  required Offset focalPoint,
  required double viewportZoom,
}) {
  final zoom = viewportZoom.isFinite && viewportZoom > 0 ? viewportZoom : 1.0;
  final scale = zoom * folioSelectionMagnifierZoom;
  return Rect.fromCenter(
    center: focalPoint,
    width: folioSelectionMagnifierSize.width / scale,
    height: folioSelectionMagnifierSize.height / scale,
  );
}

/// Applies the native MD lens style to an already-rasterized PDF crop.
class FolioSelectionMagnifierFrame extends StatelessWidget {
  const FolioSelectionMagnifierFrame({required this.child, super.key});

  final Widget child;

  static const _material = Magnifier();
  static const _radius = BorderRadius.all(
    Radius.circular(folioSelectionMagnifierCornerRadius),
  );

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: ShapeDecoration(
      shape: const RoundedRectangleBorder(borderRadius: _radius),
      shadows: _material.shadows,
    ),
    child: ClipRRect(
      borderRadius: _radius,
      clipBehavior: _material.clipBehavior,
      child: SizedBox.fromSize(
        size: folioSelectionMagnifierSize,
        child: Stack(
          fit: StackFit.expand,
          children: [
            child,
            IgnorePointer(
              child: ColoredBox(
                key: const ValueKey('selection_magnifier_film'),
                color: _material.filmColor,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
