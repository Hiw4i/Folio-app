import 'package:flutter/material.dart'
    show TextSelectionToolbar, TextSelectionToolbarAnchors;
import 'package:flutter/widgets.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../glass/liquid_glass.dart';
import '../theme/folio_theme.dart';

/// Custom context menu builder for [SelectionArea] content (plain reader text).
///
/// Shows the Folio liquid-glass toolbar instead of the platform default.
Widget folioSelectionAreaContextMenuBuilder(
  BuildContext context,
  SelectableRegionState selectableRegionState,
) {
  return FolioSelectionToolbar(
    anchors: selectableRegionState.contextMenuAnchors,
    buttonItems: selectableRegionState.contextMenuButtonItems,
  );
}

/// Same toolbar for editable/selectable text (markdown reader, search field).
Widget folioEditableTextContextMenuBuilder(
  BuildContext context,
  EditableTextState editableTextState,
) {
  return FolioSelectionToolbar(
    anchors: editableTextState.contextMenuAnchors,
    buttonItems: editableTextState.contextMenuButtonItems,
  );
}

/// Folio text-selection toolbar: одна общая liquid-пилюля, только иконки Lucide.
///
/// Показывает только copy и select all — остальные системные действия скрыты.
/// Позиционирование (above/below якоря) переиспользует [TextSelectionToolbar],
/// сама пилюля — единая liquid-поверхность на [GlassShell], а иконки внутри —
/// плоские зоны нажатия без собственного стекла.
class FolioSelectionToolbar extends StatelessWidget {
  const FolioSelectionToolbar({
    required this.anchors,
    required this.buttonItems,
    super.key,
  });

  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> buttonItems;

  @override
  Widget build(BuildContext context) {
    ContextMenuButtonItem? copy;
    ContextMenuButtonItem? selectAll;
    for (final item in buttonItems) {
      switch (item.type) {
        case ContextMenuButtonType.copy:
          copy ??= item;
        case ContextMenuButtonType.selectAll:
          selectAll ??= item;
        default:
          break;
      }
    }
    if (copy == null && selectAll == null) {
      return const SizedBox.shrink();
    }
    return TextSelectionToolbar(
      anchorAbove: anchors.primaryAnchor,
      anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
      toolbarBuilder: (context, child) => child,
      children: <Widget>[_FolioPill(copy: copy, selectAll: selectAll)],
    );
  }
}

/// Одна liquid-пилюля на весь тулбар: единая поверхность [LiquidGlass.fixed]
/// в кластер-режиме (`onTap == null`, без TouchShield) — иконки-кнопки внутри
/// остаются живыми зонами нажатия, а деформация + контент следуют за пальцем
/// как у search-эталона.
class _FolioPill extends StatelessWidget {
  const _FolioPill({required this.copy, required this.selectAll});

  final ContextMenuButtonItem? copy;
  final ContextMenuButtonItem? selectAll;

  static const double buttonExtent = 36;
  static const double edgePadding = 4;
  static const double dividerExtent = 9;
  static const double pillHeight = buttonExtent + edgePadding * 2;

  @override
  Widget build(BuildContext context) {
    final copyItem = copy;
    final selectAllItem = selectAll;
    final buttonCount =
        (copyItem == null ? 0 : 1) + (selectAllItem == null ? 0 : 1);
    final pillWidth =
        edgePadding * 2 +
        buttonCount * buttonExtent +
        (buttonCount - 1) * dividerExtent;
    // Tight-рамку держит сама универсальная поверхность внутри.
    return _FolioPillSurface(
      width: pillWidth,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (copyItem != null)
            _PillIconButton(
              key: const ValueKey<String>('folio_toolbar_copy'),
              item: copyItem,
              icon: LucideIcons.copy,
              semanticsLabel: 'Copy',
            ),
          if (copyItem != null && selectAllItem != null) const _PillDivider(),
          if (selectAllItem != null)
            _PillIconButton(
              key: const ValueKey<String>('folio_toolbar_select_all'),
              item: selectAllItem,
              icon: LucideIcons.textSelect,
              semanticsLabel: 'Select all',
            ),
        ],
      ),
    );
  }
}

class _FolioPillSurface extends StatelessWidget {
  const _FolioPillSurface({required this.width, required this.child});

  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Кластер-режим универсального вещества: поверхность тянется за пальцем,
    // внутренние иконки обрабатывают тапы сами (без TouchShield поверх).
    return LiquidGlass.fixed(
      size: Size(width, _FolioPill.pillHeight),
      child: child,
    );
  }
}

class _PillDivider extends StatelessWidget {
  const _PillDivider();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _FolioPill.dividerExtent,
      height: _FolioPill.buttonExtent,
      child: Center(
        child: SizedBox(
          width: 1,
          height: 20,
          child: AdaptiveGlassDecoration(
            child: ColoredBox(color: appColors.separator),
          ),
        ),
      ),
    );
  }
}

/// Плоская иконка-кнопка внутри пилюли: без собственного стекла,
/// только зона нажатия 36x36 с иконкой Lucide.
class _PillIconButton extends StatelessWidget {
  const _PillIconButton({
    required this.item,
    required this.icon,
    required this.semanticsLabel,
    super.key,
  });

  final ContextMenuButtonItem item;
  final IconData icon;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final onPressed = item.onPressed;
    return Semantics(
      button: true,
      label: semanticsLabel,
      onTap: onPressed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox.fromSize(
          size: const Size(_FolioPill.buttonExtent, _FolioPill.buttonExtent),
          child: Center(
            child: AdaptiveGlassEffects(
              opacity: onPressed == null ? 0.38 : 1,
              child: AdaptiveGlassIcon(icon, size: 17),
            ),
          ),
        ),
      ),
    );
  }
}
