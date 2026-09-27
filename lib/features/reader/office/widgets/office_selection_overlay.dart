import 'package:flutter/widgets.dart';

import '../../../../shared/selection/folio_selection_toolbar.dart';
import '../../../../shared/selection/selection_visuals.dart';

/// CSS visual-viewport coordinates, normalized so pinch zoom, rotation and
/// Android's device pixel ratio never get applied twice on the Flutter side.
@immutable
class OfficeSelectionSnapshot {
  const OfficeSelectionSnapshot({
    this.active = false,
    this.showMenu = false,
    this.x = 0.5,
    this.top = 0.2,
    this.bottom = 0.25,
  });

  static const empty = OfficeSelectionSnapshot();
  final bool active;
  final bool showMenu;
  final double x;
  final double top;
  final double bottom;

  factory OfficeSelectionSnapshot.fromEvent(Map<Object?, Object?> event) {
    if (event['active'] != true) {
      return empty;
    }
    double? coordinate(String key) {
      final value = event[key];
      return value is num && value.isFinite
          ? value.clamp(0.0, 1.0).toDouble()
          : null;
    }

    final x = coordinate('x');
    final top = coordinate('top');
    final bottom = coordinate('bottom');
    if (x == null || top == null || bottom == null) {
      return empty;
    }
    return OfficeSelectionSnapshot(
      active: true,
      showMenu: event['showMenu'] == true,
      x: x,
      top: top,
      bottom: bottom,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OfficeSelectionSnapshot &&
      active == other.active &&
      showMenu == other.showMenu &&
      x == other.x &&
      top == other.top &&
      bottom == other.bottom;

  @override
  int get hashCode => Object.hash(active, showMenu, x, top, bottom);
}

class OfficeSelectionOverlay extends StatelessWidget {
  const OfficeSelectionOverlay({
    required this.selection,
    required this.onCopy,
    required this.onSelectAll,
    super.key,
  });

  final OfficeSelectionSnapshot selection;
  final VoidCallback onCopy;
  final VoidCallback onSelectAll;

  @override
  Widget build(BuildContext context) {
    if (!selection.active || !selection.showMenu) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final x = selection.x * constraints.maxWidth;
        return Align(
          alignment: Alignment.topLeft,
          child: FolioSelectionToolbar(
            anchors: folioVisibleSelectionAnchors(
              original: TextSelectionToolbarAnchors(
                primaryAnchor: Offset(x, selection.top * constraints.maxHeight),
                secondaryAnchor: Offset(
                  x,
                  selection.bottom * constraints.maxHeight,
                ),
              ),
              viewport: Offset.zero & constraints.biggest,
              visibleRects: <Rect>[
                Rect.fromLTRB(
                  x - 1,
                  selection.top * constraints.maxHeight,
                  x + 1,
                  selection.bottom * constraints.maxHeight,
                ),
              ],
            ),
            buttonItems: <ContextMenuButtonItem>[
              ContextMenuButtonItem(
                type: ContextMenuButtonType.copy,
                onPressed: onCopy,
              ),
              ContextMenuButtonItem(
                type: ContextMenuButtonType.selectAll,
                onPressed: onSelectAll,
              ),
            ],
          ),
        );
      },
    );
  }
}
