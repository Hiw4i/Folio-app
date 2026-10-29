import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
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

/// Optional placement storage for a selection whose menu is hidden and rebuilt.
///
/// Keep one instance in the selection owner and change the toolbar's
/// [FolioSelectionToolbar.selectionId] when a new selection begins. This object
/// owns no resources and does not need disposal.
class FolioSelectionToolbarController {
  Object? _selectionId;
  double? _horizontalAnchor;
  Offset? _pinnedPosition;
  bool? _preferAbove;

  void _select(Object? selectionId, double horizontalAnchor) {
    if (_selectionId != selectionId) {
      _selectionId = selectionId;
      _horizontalAnchor = null;
      _pinnedPosition = null;
      _preferAbove = null;
    }
    _horizontalAnchor ??= horizontalAnchor;
  }
}

/// Folio text-selection toolbar: одна общая liquid-пилюля, только иконки Lucide.
///
/// Reader (read-only) показывает copy/select all. Редактируемый текст
/// (поле поиска) дополнительно показывает cut/paste — иначе в поиск
/// невозможно вставить текст. Остальные системные действия скрыты.
/// The horizontal anchor stays fixed for the current selection while the menu
/// follows its vertical anchors. Drag anywhere on the pill immediately to
/// pin it instead. Placement always stays inside the visible safe area.
class FolioSelectionToolbar extends StatefulWidget {
  const FolioSelectionToolbar({
    required this.anchors,
    required this.buttonItems,
    this.selectionId,
    this.controller,
    super.key,
  });

  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> buttonItems;

  /// Changes only when a new selection begins, never on scrolling or resizing.
  /// A changed identity clears both the captured horizontal anchor and the pin.
  final Object? selectionId;

  final FolioSelectionToolbarController? controller;

  @override
  State<FolioSelectionToolbar> createState() => _FolioSelectionToolbarState();
}

class _FolioSelectionToolbarState extends State<FolioSelectionToolbar>
    with SingleTickerProviderStateMixin {
  final _localController = FolioSelectionToolbarController();
  final _layoutKey = GlobalKey();
  final _pillKey = GlobalKey();
  Offset? _dragStart;
  Offset? _pointerStart;
  late final AnimationController _motion;
  Offset? _position;
  Offset? _motionStart;
  Offset? _motionTarget;
  bool _motionScheduled = false;
  Duration _motionStartedAt = Duration.zero;
  static const _motionDuration = Duration(milliseconds: 140);

  FolioSelectionToolbarController get _placement =>
      widget.controller ?? _localController;

  @override
  void initState() {
    super.initState();
    _motion = AnimationController(vsync: this, duration: _motionDuration);
    _select();
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  Offset _animatedPosition(Offset target) {
    // A drag is direct manipulation, not a series of animated destinations.
    // Keep animation state at the pointer so release cannot replay old motion.
    if (_dragStart != null) {
      _position = _motionStart = _motionTarget = target;
      return target;
    }
    if (_position == null) {
      _position = _motionStart = _motionTarget = target;
      return target;
    }
    if (!_motionScheduled) {
      _position = Offset.lerp(
        _motionStart,
        _motionTarget,
        Curves.easeOutCubic.transform(
          ((WidgetsBinding.instance.currentFrameTimeStamp - _motionStartedAt)
                      .inMicroseconds /
                  _motionDuration.inMicroseconds)
              .clamp(0.0, 1.0),
        ),
      );
    }
    if ((_motionTarget! - target).distance > 0.75) {
      _motionStart = _position;
      _motionTarget = target;
      _motionStartedAt = WidgetsBinding.instance.currentFrameTimeStamp;
      // Layout discovers the clamped target only after measuring the pill.
      // Start the ticker after layout so its notifications cannot dirty an
      // ancestor in the middle of laying out its child.
      if (!_motionScheduled) {
        _motionScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _motionScheduled = false;
          if (_dragStart != null || _position == _motionTarget) return;
          _motion.forward(from: 0);
        });
      }
    }
    return _position!;
  }

  @override
  void didUpdateWidget(FolioSelectionToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectionId != widget.selectionId ||
        oldWidget.controller != widget.controller) {
      _dragStart = null;
      _pointerStart = null;
    }
    _select();
  }

  void _select() =>
      _placement._select(widget.selectionId, widget.anchors.primaryAnchor.dx);

  void _startDrag(DragStartDetails details) {
    final layout = _layoutKey.currentContext?.findRenderObject();
    final pill = _pillKey.currentContext?.findRenderObject();
    if (layout is! RenderBox || pill is! RenderBox) return;
    _motion.stop();
    _dragStart = layout.globalToLocal(pill.localToGlobal(Offset.zero));
    _pointerStart = details.globalPosition;
    setState(() => _placement._pinnedPosition = _dragStart);
  }

  void _updateDrag(DragUpdateDetails details) {
    final start = _dragStart;
    final pointer = _pointerStart;
    final layout = _layoutKey.currentContext?.findRenderObject();
    if (start == null || pointer == null || layout is! RenderBox) return;
    final delta =
        layout.globalToLocal(details.globalPosition) -
        layout.globalToLocal(pointer);
    setState(() => _placement._pinnedPosition = start + delta);
  }

  void _finishDrag() {
    _dragStart = null;
    _pointerStart = null;
  }

  @override
  Widget build(BuildContext context) {
    ContextMenuButtonItem? cut;
    ContextMenuButtonItem? copy;
    ContextMenuButtonItem? paste;
    ContextMenuButtonItem? selectAll;
    for (final item in widget.buttonItems) {
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
    final media = MediaQuery.of(context);
    final topInset = math.max(media.padding.top, media.viewInsets.top) + 8;
    _placement._preferAbove ??=
        widget.anchors.primaryAnchor.dy - 8 - _FolioPill.pillHeight >= topInset;
    return CustomSingleChildLayout(
      key: _layoutKey,
      delegate: _FolioToolbarLayout(
        motion: _motion,
        animatePosition: _animatedPosition,
        anchors: widget.anchors,
        horizontalAnchor: _placement._horizontalAnchor!,
        pinnedPosition: _placement._pinnedPosition,
        preferAbove: _placement._preferAbove!,
        padding: EdgeInsets.fromLTRB(
          math.max(media.padding.left, media.viewInsets.left) + 8,
          math.max(media.padding.top, media.viewInsets.top) + 8,
          math.max(media.padding.right, media.viewInsets.right) + 8,
          math.max(media.padding.bottom, media.viewInsets.bottom) + 8,
        ),
      ),
      child: GestureDetector(
        key: _pillKey,
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        dragStartBehavior: DragStartBehavior.down,
        onPanStart: _startDrag,
        onPanUpdate: _updateDrag,
        onPanEnd: (_) => _finishDrag(),
        onPanCancel: _finishDrag,
        child: _FolioPill(actions: actions),
      ),
    );
  }
}

class _FolioToolbarLayout extends SingleChildLayoutDelegate {
  _FolioToolbarLayout({
    required AnimationController motion,
    required this.animatePosition,
    required this.anchors,
    required this.horizontalAnchor,
    required this.pinnedPosition,
    required this.preferAbove,
    required this.padding,
  }) : super(relayout: motion);

  final Offset Function(Offset target) animatePosition;
  final TextSelectionToolbarAnchors anchors;
  final double horizontalAnchor;
  final Offset? pinnedPosition;
  final bool preferAbove;
  final EdgeInsets padding;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = math.min(
      padding.left,
      math.max(0.0, size.width - childSize.width),
    );
    final top = math.min(
      padding.top,
      math.max(0.0, size.height - childSize.height),
    );
    final right = math.max(left, size.width - padding.right - childSize.width);
    final bottom = math.max(
      top,
      size.height - padding.bottom - childSize.height,
    );
    final above = anchors.primaryAnchor.dy - 8 - childSize.height;
    final below = (anchors.secondaryAnchor ?? anchors.primaryAnchor).dy + 20;
    final desired =
        pinnedPosition ??
        Offset(
          horizontalAnchor - childSize.width / 2,
          preferAbove ? above : below,
        );
    final target = Offset(
      desired.dx.clamp(left, right).toDouble(),
      desired.dy <= top + 0.75
          ? top
          : desired.dy >= bottom - 0.75
          ? bottom
          : desired.dy,
    );
    final animated = animatePosition(target);
    return Offset(
      animated.dx.clamp(left, right).toDouble(),
      animated.dy.clamp(top, bottom).toDouble(),
    );
  }

  @override
  bool shouldRelayout(_FolioToolbarLayout oldDelegate) =>
      anchors.primaryAnchor != oldDelegate.anchors.primaryAnchor ||
      anchors.secondaryAnchor != oldDelegate.anchors.secondaryAnchor ||
      horizontalAnchor != oldDelegate.horizontalAnchor ||
      pinnedPosition != oldDelegate.pinnedPosition ||
      preferAbove != oldDelegate.preferAbove ||
      padding != oldDelegate.padding;
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
