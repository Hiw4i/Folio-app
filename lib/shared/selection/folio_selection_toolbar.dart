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
/// Reader (read-only) показывает copy/select all. Редактируемый текст
/// (поле поиска) дополнительно показывает cut/paste — иначе в поиск
/// невозможно вставить текст. Остальные системные действия скрыты.
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
    ContextMenuButtonItem? cut;
    ContextMenuButtonItem? copy;
    ContextMenuButtonItem? paste;
    ContextMenuButtonItem? selectAll;
    for (final item in buttonItems) {
      switch (item.type) {
        case ContextMenuButtonType.cut:
          cut ??= item;
        case ContextMenuButtonType.copy:
          copy ??= item;
        case ContextMenuButtonType.paste:
          paste ??= item;
        case ContextMenuButtonType.selectAll:
          selectAll ??= item;
        default:
          break;
      }
    }
    final actions = <_PillAction>[
      if (cut != null)
        _PillAction(
          item: cut,
          icon: LucideIcons.scissors,
          semanticsLabel: 'Cut',
          key: const ValueKey<String>('folio_toolbar_cut'),
        ),
      if (copy != null)
        _PillAction(
          item: copy,
          icon: LucideIcons.copy,
          semanticsLabel: 'Copy',
          key: const ValueKey<String>('folio_toolbar_copy'),
        ),
      if (paste != null)
        _PillAction(
          item: paste,
          icon: LucideIcons.clipboardPaste,
          semanticsLabel: 'Paste',
          key: const ValueKey<String>('folio_toolbar_paste'),
        ),
      if (selectAll != null)
        _PillAction(
          item: selectAll,
          icon: LucideIcons.textSelect,
          semanticsLabel: 'Select all',
          key: const ValueKey<String>('folio_toolbar_select_all'),
        ),
    ];
    if (actions.isEmpty) {
      return const SizedBox.shrink();
    }
    return TextSelectionToolbar(
      anchorAbove: anchors.primaryAnchor,
      anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
      toolbarBuilder: (context, child) => child,
      children: <Widget>[_FolioPill(actions: actions)],
    );
  }
}

class _PillAction {
  const _PillAction({
    required this.item,
    required this.icon,
    required this.semanticsLabel,
    required this.key,
  });

  final ContextMenuButtonItem item;
  final IconData icon;
  final String semanticsLabel;
  final Key key;
}

/// Одна liquid-пилюля на весь тулбар: единая поверхность [LiquidGlass.fixed]
/// в кластер-режиме (`onTap == null`, без TouchShield) — иконки-кнопки внутри
/// остаются живыми зонами нажатия, а деформация + контент следуют за пальцем
/// как у search-эталона.
class _FolioPill extends StatelessWidget {
  const _FolioPill({required this.actions});

  final List<_PillAction> actions;

  static const double buttonExtent = 36;
  static const double edgePadding = 4;
  static const double dividerExtent = 9;
  static const double pillHeight = buttonExtent + edgePadding * 2;

  @override
  Widget build(BuildContext context) {
    final pillWidth =
        edgePadding * 2 +
        actions.length * buttonExtent +
        (actions.length - 1) * dividerExtent;
    // Tight-рамку держит сама универсальная поверхность внутри.
    return _FolioPillSurface(
      width: pillWidth,
      child: Row(
        mainAxisSize: MainAxisSize.min,

        children: <Widget>[
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) const _PillDivider(),

            _PillIconButton(
              key: actions[i].key,
              item: actions[i].item,
              icon: actions[i].icon,
              semanticsLabel: actions[i].semanticsLabel,
            ),
          ],
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
