part of 'folio_selection_toolbar.dart';

/// Owns the presentation separately from a framework's short-lived menu entry.
/// Place above the Navigator so text, PDF and platform-view menus share one
/// surface and can finish exiting after their selection owner removes them.
class FolioSelectionToolbarHost extends StatefulWidget {
  const FolioSelectionToolbarHost({required this.child, super.key});

  final Widget child;

  @override
  State<FolioSelectionToolbarHost> createState() => _FolioToolbarHostState();
}

class _FolioToolbarHostState extends State<FolioSelectionToolbarHost> {
  Object? _owner;
  FolioSelectionToolbar? _toolbar;
  Object? _pendingOwner;
  FolioSelectionToolbar? _pendingToolbar;
  bool _scheduled = false;
  bool _visible = false;
  int _selectionEpoch = 0;

  void present(Object owner, FolioSelectionToolbar toolbar) {
    if (!toolbar.buttonItems.any(
      (item) => switch (item.type) {
        ContextMenuButtonType.cut ||
        ContextMenuButtonType.copy ||
        ContextMenuButtonType.paste ||
        ContextMenuButtonType.selectAll => true,
        _ => false,
      },
    )) {
      release(owner);
      return;
    }
    _pendingOwner = owner;
    _pendingToolbar = toolbar;
    _schedule();
  }

  void release(Object owner) {
    if (identical(_pendingOwner, owner)) {
      _pendingOwner = null;
      _pendingToolbar = null;
    } else if (!identical(_owner, owner) || _pendingOwner != null) {
      return;
    }
    _schedule();
  }

  void _schedule() {
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.postFrameCallbacks) {
      _applyPending();
      return;
    }
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      _applyPending();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _applyPending() {
    if (!mounted) return;
    setState(() {
      if (_pendingToolbar != null) {
        if (!_visible || !identical(_owner, _pendingOwner)) _selectionEpoch++;
        _toolbar = _pendingToolbar;
        _owner = _pendingOwner;
        _visible = true;
      } else {
        _owner = null;
        _visible = false;
      }
    });
  }

  void _hidden() {
    if (mounted && !_visible) setState(() => _toolbar = null);
  }

  @override
  Widget build(BuildContext context) {
    final toolbar = _toolbar;
    return Stack(
      fit: StackFit.expand,
      children: [
        _FolioToolbarScope(host: this, child: widget.child),
        if (toolbar != null)
          Positioned.fill(
            // The retained surface lives outside Flutter's short-lived menu
            // wrapper. Keep its public tap regions so desktop pointer-down
            // cannot unfocus the selected field before an action receives up.
            child: TapRegion(
              groupId: SelectableRegion,
              child: TextFieldTapRegion(
                child: _FolioSelectionToolbarSurface(
                  anchors: toolbar.anchors,
                  buttonItems: toolbar.buttonItems,
                  selectionId: toolbar.selectionId ?? _selectionEpoch,
                  controller: toolbar.controller,
                  visible: _visible,
                  onHidden: _hidden,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _FolioToolbarScope extends InheritedWidget {
  const _FolioToolbarScope({required this.host, required super.child});

  final _FolioToolbarHostState host;

  @override
  bool updateShouldNotify(_FolioToolbarScope oldWidget) =>
      host != oldWidget.host;
}
