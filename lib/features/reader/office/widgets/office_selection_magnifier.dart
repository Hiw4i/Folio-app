import 'package:flutter/material.dart' show Magnifier;
import 'package:flutter/widgets.dart';

import '../../../../shared/selection/selection_visuals.dart';

/// DOM handle coordinates are already relative to the visible Office viewport.
/// They must not receive another device-pixel-ratio or document-zoom transform.
Offset? officeSelectionMagnifierSource(Map<Object?, Object?> event) {
  final x = event['x'];
  final y = event['y'];
  if (event['active'] != true ||
      x is! num ||
      y is! num ||
      !x.isFinite ||
      !y.isFinite) {
    return null;
  }
  return Offset(x.clamp(0.0, 1.0).toDouble(), y.clamp(0.0, 1.0).toDouble());
}

/// Samples the same Flutter-composited Office texture as the glass controls.
/// Android's window magnifier cannot sample an offscreen TLHC WebView surface.
class OfficeSelectionMagnifier extends StatelessWidget {
  const OfficeSelectionMagnifier({required this.normalizedSource, super.key});

  final Offset normalizedSource;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewport = constraints.biggest;
          final source = Offset(
            normalizedSource.dx * viewport.width,
            normalizedSource.dy * viewport.height,
          );
          const lens = folioSelectionMagnifierSize;
          final shift =
              Magnifier.kStandardVerticalFocalPointShift + lens.height / 2;
          final left = (source.dx - lens.width / 2).clamp(
            0.0,
            (viewport.width - lens.width).clamp(0.0, double.infinity),
          );
          final top = (source.dy - shift - lens.height / 2).clamp(
            0.0,
            (viewport.height - lens.height).clamp(0.0, double.infinity),
          );
          final center = Offset(left + lens.width / 2, top + lens.height / 2);
          return Stack(
            children: [
              Positioned(
                left: left,
                top: top,
                child: Magnifier(
                  additionalFocalPointOffset:
                      source - center - Offset(0, shift),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
