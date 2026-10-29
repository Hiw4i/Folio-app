import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart'
    show
        cupertinoDesktopTextSelectionHandleControls,
        cupertinoTextSelectionHandleControls;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart'
    show
        Theme,
        desktopTextSelectionHandleControls,
        materialTextSelectionHandleControls;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../shared/selection/folio_selection_toolbar.dart';
import '../../../../shared/selection/selection_magnifier.dart';
import '../../../../shared/selection/selection_visuals.dart';
import '../data/text_document.dart';
import '../logic/selection_edge_scroller.dart';
import 'text_selection_source.dart';
import 'reader_selection_handle_controls.dart';

/// One selection owner for the entire lazy reader, not one editor per paragraph.
/// Full-document Copy reads the source only on explicit user action; it never
/// forces every off-screen chunk to build just to implement Select all.
class TextDocumentSelection extends StatefulWidget {
  const TextDocumentSelection({
    required this.document,
    required this.child,
    this.onSelectionChanged,
    this.scrollController,
    super.key,
  });

  final TextDocument document;
  final Widget child;
  final ValueChanged<bool>? onSelectionChanged;
  final ScrollController? scrollController;

  @override
  State<TextDocumentSelection> createState() => _TextDocumentSelectionState();
}

class _TextDocumentSelectionState extends State<TextDocumentSelection>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final _regionKey = GlobalKey<SelectableRegionState>();
  final _containerKey = GlobalKey();
  final _visualKey = GlobalKey();
  final _focusNode = FocusNode(debugLabel: 'Document selection');
  final Set<int> _touchPointers = <int>{};
  final _delegate = _DocumentSelectionDelegate();
  final _visualRepaint = _SelectionVisualNotifier();
  final _toolbarPlacement = FolioSelectionToolbarController();
  TextSelectionToolbarAnchors? _menuAnchor;
  int? _menuAnchorSelection;
  double _menuAnchorScroll = 0;
  Size? _menuViewportSize;
  final _sourceRegistry = TextSelectionSourceRegistry();
  final _pointers = <int, PointerEvent>{};
  SelectionEdgeScroller? _edgeScroller;
  SelectionEdgeUpdateEvent? _dragEdge;
  int? _dragPointer;
  int _selectionId = 0;
  bool _initialTouchDrag = false;
  bool _replayScheduled = false;
  bool _toolbarSyncScheduled = false;
  bool _appActive = true;
  bool _copying = false;
  bool _hasSelection = false;
  bool _handleDragging = false;
  bool _handleStart = false;
  Offset _handleOffset = Offset.zero;
  double _handleLineHeight = 20;
  Object? _handleLine;
  final _handleMenu = ContextMenuController();
  final _magnifier = MagnifierController();
  final _magnifierInfo = ValueNotifier<MagnifierInfo>(MagnifierInfo.empty);
  int? _sourceStart;
  int? _sourceEnd;

  @override
  void initState() {
    super.initState();
    _delegate.addListener(_refreshVisual);
    _delegate.transformEdge = _transformEdge;
    _delegate.onSelectionEvent = _selectionEvent;
    _focusNode.addListener(_focusChanged);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_trackPointer);
    WidgetsBinding.instance.addObserver(this);
    _configureScroller();
  }

  void _configureScroller() {
    _edgeScroller?.dispose();
    _edgeScroller = widget.scrollController == null
        ? null
        : SelectionEdgeScroller(
            vsync: this,
            scrollController: () => widget.scrollController!,
            viewport: _globalViewport,
            onScrolled: _replayDragAfterLayout,
          );
  }

  Rect? _globalViewport() {
    final object = _visualKey.currentContext?.findRenderObject();
    if (object is! RenderBox || !object.hasSize || !object.attached) {
      return null;
    }
    return MatrixUtils.transformRect(
      object.getTransformTo(null),
      Offset.zero & object.size,
    );
  }

  void _stopDrag() {
    _edgeScroller?.stop();
    _dragEdge = null;
    _dragPointer = null;
    _initialTouchDrag = false;
    _handleDragging = false;
    _magnifier.hide();
  }

  void _startHandle(
    TextSelectionHandleType type,
    double height,
    Offset finger,
  ) {
    final box = _containerKey.currentContext?.findRenderObject();
    final geometry = _delegate.value;
    if (box is! RenderBox ||
        geometry.startSelectionPoint == null ||
        geometry.endSelectionPoint == null ||
        _handleDragging) {
      return;
    }
    final start = box.localToGlobal(
      geometry.startSelectionPoint!.localPosition,
    );
    final end = box.localToGlobal(geometry.endSelectionPoint!.localPosition);
    _handleStart =
        (start - finger).distanceSquared <= (end - finger).distanceSquared;
    if (_handleStart) _menuAnchor = null;
    final point = _handleStart ? start : end;
    _handleOffset = point - finger - Offset(0, height / 2);
    _handleLineHeight = height;
    _handleDragging = true;
    _handleLine = _lineAt(point - Offset(0, height / 2));
    _regionKey.currentState?.hideToolbar(false);
    _handleMenu.remove();
    _updateHandle(finger);
    final config = folioTextMagnifierConfiguration;
    final builder = config.magnifierBuilder;
    _magnifier.show(
      context: context,
      builder: (context) =>
          builder(context, _magnifier, _magnifierInfo) ??
          const SizedBox.shrink(),
    );
  }

  Object? _lineAt(Offset point) {
    final root = _containerKey.currentContext?.findRenderObject();
    RenderParagraph? nearest;
    var distance = double.infinity;
    void visit(RenderObject object) {
      if (object is RenderParagraph &&
          object.hasSize &&
          object.registrar != null) {
        final local = object.globalToLocal(point);
        final dx = local.dx - local.dx.clamp(0, object.size.width);
        final dy = local.dy - local.dy.clamp(0, object.size.height);
        final squared = dx * dx + dy * dy;
        if (squared < distance) {
          nearest = object;
          distance = squared;
        }
      }
      object.visitChildren(visit);
    }

    if (root == null) return null;
    visit(root);
    final paragraph = nearest;
    if (paragraph == null) return null;
    final position = paragraph.getPositionForOffset(
      paragraph.globalToLocal(point),
    );
    final length = paragraph.text.toPlainText().length;
    if (length == 0) return null;
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(
        baseOffset: 0,
        extentOffset: position.offset.clamp(1, length),
      ),
      boxHeightStyle: ui.BoxHeightStyle.strut,
    );
    return boxes.isEmpty ? null : (paragraph, boxes.last.top);
  }

  void _updateHandle(Offset finger) {
    if (!_handleDragging) return;
    final point = finger + _handleOffset;
    _delegate.dispatchSelectionEvent(
      _handleStart
          ? SelectionEdgeUpdateEvent.forStart(globalPosition: point)
          : SelectionEdgeUpdateEvent.forEnd(globalPosition: point),
    );
    final bounds = _globalViewport() ?? Rect.zero;
    _magnifierInfo.value = MagnifierInfo(
      globalGesturePosition: finger,
      caretRect: Rect.fromCenter(
        center: point,
        width: 0,
        height: _handleLineHeight,
      ),
      fieldBounds: bounds,
      currentLineBoundaries: bounds,
    );
  }

  void _endHandle() {
    if (!_handleDragging) return;
    _stopDrag();
    _scheduleToolbarSync();
  }

  /// Selection and its toolbar are one piece of state. Flutter's overlay and
  /// the reader's handle drags each own a [ContextMenuController] for the same
  /// pill, so one can outlive the selection or vanish while the selection
  /// remains. Reconcile both directions from the live selection once per frame
  /// instead of trusting whichever controller changed last.
  void _scheduleToolbarSync() {
    if (_toolbarSyncScheduled) return;
    _toolbarSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _toolbarSyncScheduled = false;
      _syncToolbar();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Live state, not the cached content string: off-screen anchors and lazy
  /// chunk rebuilds can leave [SelectedContent] empty while endpoints remain.
  bool get _selectionActive =>
      _delegate.selectsDocument ||
      _delegate.value.status == SelectionStatus.uncollapsed;

  void _syncToolbar() {
    final region = _regionKey.currentState;
    if (!mounted || region == null) return;
    // A backgrounded app must not resurrect a menu that the lifecycle event
    // just dismissed; the selection is restored on resume instead.
    if (!_appActive) {
      if (_handleMenu.isShown) _handleMenu.remove();
      return;
    }
    if (!_selectionActive) {
      _menuAnchor = null;
      if (_handleMenu.isShown) _handleMenu.remove();
      // A collapsed selection must not leave the framework's pill or handles.
      // During a handle drag the framework still owns the overlay: its gesture
      // end (or [_endHandle]) hides it, so do not yank the handle mid-drag.
      if (!_handleDragging && _pointers.isEmpty) {
        region.hideToolbar();
      }
      return;
    }
    // Mid-gesture the framework hides the toolbar on drag start and shows it on
    // drag end; handle drags hide it too. Showing during a pointer sequence
    // would make the pill flicker under the finger.
    if (_handleDragging || _pointers.isNotEmpty) return;
    _handleMenu.show(
      context: context,
      contextMenuBuilder: (context) => _menu(context, region),
    );
  }

  void _trackPointer(PointerEvent event) {
    if (event is PointerDownEvent) {
      _pointers[event.pointer] = event;
    } else if (event is PointerMoveEvent &&
        _pointers.containsKey(event.pointer)) {
      _pointers[event.pointer] = event;
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _pointers.remove(event.pointer);
      if (_dragPointer == event.pointer || _pointers.isEmpty) _stopDrag();
      _scheduleToolbarSync();
    }
  }

  SelectionEdgeUpdateEvent _transformEdge(SelectionEdgeUpdateEvent event) {
    if (_pointers.isEmpty) return event;
    _dragPointer ??= _pointers.values
        .reduce(
          (a, b) =>
              (a.position - event.globalPosition).distanceSquared <=
                  (b.position - event.globalPosition).distanceSquared
              ? a
              : b,
        )
        .pointer;
    _dragEdge = event;
    _edgeScroller?.update(event.globalPosition);
    final viewport = _edgeScroller == null ? null : _globalViewport();
    final position =
        viewport == null ||
            !viewport.isFinite ||
            viewport.width <= 2 ||
            viewport.height <= 2
        ? event.globalPosition
        : Offset(
            event.globalPosition.dx.clamp(
              viewport.left + 1,
              viewport.right - 1,
            ),
            event.globalPosition.dy.clamp(
              viewport.top + 1,
              viewport.bottom - 1,
            ),
          );
    // Flutter's own auto-scroller starts outside the viewport and would race
    // the reader's dwell-based policy. Keep its target strictly inside it.
    return event.type == SelectionEventType.startEdgeUpdate
        ? SelectionEdgeUpdateEvent.forStart(
            globalPosition: position,
            granularity: event.granularity,
          )
        : SelectionEdgeUpdateEvent.forEnd(
            globalPosition: position,
            granularity: event.granularity,
          );
  }

  void _replayDragAfterLayout() {
    if (_replayScheduled) return;
    _replayScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _replayScheduled = false;
      final event = _dragEdge;
      if (!mounted || event == null || !_pointers.containsKey(_dragPointer)) {
        return;
      }
      _delegate.dispatchSelectionEvent(event);
    });
  }

  void _selectionEvent(SelectionEvent event, SelectedContentRange? before) {
    // Reader-owned handle gestures bypass SelectableRegion's gesture callbacks.
    // Keep the reader's active-selection state synchronized with live content.
    if (_handleDragging) {
      _selectionChanged(_delegate.getSelectedContent());
    }
    switch (event.type) {
      case SelectionEventType.selectWord:
      case SelectionEventType.selectParagraph:
        _selectionId++;
        _initialTouchDrag = _touchPointers.isNotEmpty;
      case SelectionEventType.selectAll:
      case SelectionEventType.clear:
        _selectionId++;
        _stopDrag();
      default:
        break;
    }
    if (event.type == SelectionEventType.clear) {
      _handleMenu.remove();
      _sourceStart = null;
      _sourceEnd = null;
    } else if (event is SelectionEdgeUpdateEvent) {
      final endpoint = _sourceRegistry.sourceEndpoint(event);
      if (event.type == SelectionEventType.startEdgeUpdate) {
        _sourceStart = endpoint ?? _sourceStart;
      } else {
        _sourceEnd = endpoint ?? _sourceEnd;
      }
      if (_sourceStart == null || _sourceEnd == null) {
        final range = _sourceRegistry.selectedSourceRange;
        final selection = _delegate.getSelection();
        final forward =
            selection == null || selection.endOffset >= selection.startOffset;
        _sourceStart ??= forward ? range?.start : range?.end;
        _sourceEnd ??= forward ? range?.end : range?.start;
      }
      final start = _sourceStart;
      final end = _sourceEnd;
      final live = _sourceRegistry.selectedSourceRange;
      if (start != null && end != null && live != null) {
        final forward = start <= end;
        // Complete Markdown nodes expand to include their syntax. Recompute
        // both boundaries while mounted so shrinking a word cannot leave an
        // unmatched opening marker. Only offscreen anchors retain snapshots.
        if (_sourceRegistry.containsSourceOffset(forward ? start : end)) {
          if (forward) {
            _sourceStart = live.start;
          } else {
            _sourceEnd = live.start;
          }
        }
        if (_sourceRegistry.containsSourceOffset(
          forward ? end : start,
          upstream: true,
        )) {
          if (forward) {
            _sourceEnd = live.end;
          } else {
            _sourceStart = live.end;
          }
        }
      }
    } else if (event.type != SelectionEventType.selectAll) {
      final range = _sourceRegistry.selectedSourceRange;
      _sourceStart = range?.start;
      _sourceEnd = range?.end;
    }
    if (_initialTouchDrag &&
        event is SelectionEdgeUpdateEvent &&
        before != _delegate.getSelection()) {
      unawaited(HapticFeedback.selectionClick());
    }
    if (_handleDragging && event is SelectionEdgeUpdateEvent) {
      final line = _lineAt(event.globalPosition);
      final scrolling = _edgeScroller?.scrolling ?? false;
      if (scrolling
          ? line != null && line != _handleLine
          : before != _delegate.getSelection()) {
        unawaited(HapticFeedback.selectionClick());
      }
      _handleLine = line;
    }
    _scheduleToolbarSync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A rotation hides the platform toolbar but keeps the selection; rebuild
    // it for the new orientation from the live endpoints.
    _scheduleToolbarSync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    if (!_appActive) {
      _stopDrag();
      _touchPointers.clear();
      _pointers.clear();
    }
    _scheduleToolbarSync();
  }

  void _focusChanged() {
    if (_focusNode.hasFocus) return;
    _stopDrag();
    _handleMenu.remove();
    _touchPointers.clear();
    _regionKey.currentState?.clearSelection();
    _refreshVisual();
  }

  @override
  void didUpdateWidget(TextDocumentSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.scrollController != oldWidget.scrollController) {
      _stopDrag();
      _configureScroller();
    }
    if (!identical(widget.document, oldWidget.document)) {
      _sourceStart = null;
      _sourceEnd = null;
      _touchPointers.clear();
      _stopDrag();
      _delegate.invalidate();
      _refreshVisual();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _regionKey.currentState?.clearSelection();
        }
      });
    }
  }

  void _pointerDown(PointerDownEvent event) {
    // Mouse drags must remain native range-selection gestures. Touch/stylus
    // cancellation, on the other hand, usually means a scroll won the arena.
    if (event.kind == PointerDeviceKind.touch ||
        event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus) {
      _touchPointers.add(event.pointer);
    }
  }

  void _pointerFinished(PointerEvent event) {
    // Render-object Listeners run before the gesture arena processes up/cancel.
    // Keep the guard through that dispatch, not just until our Listener sees up.
    // Native taps/long presses still dispatch edge/word events normally.
    scheduleMicrotask(() {
      if (mounted) _touchPointers.remove(event.pointer);
    });
  }

  void _selectionChanged(SelectedContent? content) {
    final active = content?.plainText.isNotEmpty ?? false;
    if (_hasSelection == active) {
      return;
    }
    _hasSelection = active;
    widget.onSelectionChanged?.call(active);
    _refreshVisual();
  }

  void _refreshVisual() {
    _visualRepaint.refresh();
    _scheduleToolbarSync();
  }

  List<Rect> _visibleHighlightRects() {
    final paintBox = _visualKey.currentContext?.findRenderObject();
    final containerBox = _containerKey.currentContext?.findRenderObject();
    if (paintBox is! RenderBox ||
        containerBox is! RenderBox ||
        !paintBox.hasSize ||
        !containerBox.hasSize) {
      return const <Rect>[];
    }
    final selectsDocument = _delegate.selectsDocument;
    final rects = <Rect>[];
    void visit(RenderObject object) {
      if (object is RenderParagraph && object.hasSize) {
        final transform = object.getTransformTo(paintBox);
        void addRange(int start, int end) {
          if (start == end) return;
          for (final line in object.getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: end),
            boxHeightStyle: ui.BoxHeightStyle.strut,
          )) {
            final rect = MatrixUtils.transformRect(transform, line.toRect());
            if (rect.isFinite && !rect.isEmpty) rects.add(rect);
          }
        }

        if (selectsDocument) {
          addRange(0, object.text.toPlainText().length);
        } else if (object.registrar
            case final MultiSelectableSelectionContainerDelegate registrar) {
          // Read the owning paragraph's character offsets, not Scrollable's
          // aggregate rectangles (refreshed after paint). Source offsets and
          // paragraph transforms stay in the same frame while scrolling.
          for (final selectable in registrar.selectables) {
            if (!object.selectableBelongsToParagraph(selectable)) continue;
            final range = selectable.getSelection();
            if (range != null) addRange(range.startOffset, range.endOffset);
          }
        }
      }
      object.visitChildren(visit);
    }

    // Keep neighboring offscreen lines; clipping the inputs would change the
    // joined silhouette as its first visible line crosses the viewport edge.
    // The painter clips the final path. Lazy layout bounds the visited content.
    visit(containerBox);
    return rects;
  }

  Future<void> _copy(SelectableRegionState region) async {
    if (_copying || !_selectionActive) {
      return;
    }
    if (!_delegate.selectsDocument && !widget.document.isMarkdown) {
      for (final item in region.contextMenuButtonItems) {
        if (item.type == ContextMenuButtonType.copy) {
          item.onPressed?.call();
          return;
        }
      }
      return;
    }
    _copying = true;
    final document = widget.document;
    final revision = _delegate.revision;
    try {
      var text = document.text;
      if (!_delegate.selectsDocument) {
        final range = _sourceRegistry.selectedSourceRange;
        final start = _sourceStart ?? range?.start;
        final end = _sourceEnd ?? range?.end;
        if (start == null || end == null) return;
        final lower = start < end ? start : end;
        final upper = start < end ? end : start;
        text = text.substring(
          lower.clamp(0, text.length),
          upper.clamp(0, text.length),
        );
      }
      if (!mounted ||
          !identical(widget.document, document) ||
          revision != _delegate.revision) {
        return;
      }
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted &&
          identical(widget.document, document) &&
          revision == _delegate.revision) {
        region.hideToolbar();
        _touchPointers.clear();
        region.clearSelection();
        _scheduleToolbarSync();
      }
    } catch (error) {
      // Do not discard the user's selection on a failed clipboard operation.
      debugPrint('Folio text copy failed: $error');
    } finally {
      _copying = false;
    }
  }

  Widget _menu(BuildContext context, SelectableRegionState region) {
    final paintBox = _visualKey.currentContext?.findRenderObject();
    final viewport = paintBox is RenderBox
        ? MatrixUtils.transformRect(
            paintBox.getTransformTo(null),
            Offset.zero & paintBox.size,
          )
        : Offset.zero & MediaQuery.sizeOf(context);
    final visibleRects = paintBox is RenderBox
        ? _visibleHighlightRects().map(
            (rect) =>
                MatrixUtils.transformRect(paintBox.getTransformTo(null), rect),
          )
        : const <Rect>[];
    TextSelectionToolbarAnchors? original;
    try {
      // Flutter's start/end glyph heights can be absent after both handles
      // have scrolled out of a lazily built viewport.
      original = region.contextMenuAnchors;
    } catch (_) {
      original = null;
    }
    final scroll = widget.scrollController;
    final scrollOffset = scroll != null && scroll.positions.length == 1
        ? scroll.offset
        : 0.0;
    if (_menuAnchor == null ||
        _menuAnchorSelection != _selectionId ||
        _menuViewportSize != viewport.size) {
      _menuAnchor = folioVisibleSelectionAnchors(
        original: original,
        viewport: viewport,
        visibleRects: visibleRects,
      );
      _menuAnchorSelection = _selectionId;
      _menuViewportSize = viewport.size;
      _menuAnchorScroll = scrollOffset;
    }
    final shift = Offset(0, _menuAnchorScroll - scrollOffset);
    return FolioSelectionToolbar(
      controller: _toolbarPlacement,
      selectionId: _selectionId,
      anchors: TextSelectionToolbarAnchors(
        primaryAnchor: _menuAnchor!.primaryAnchor + shift,
        secondaryAnchor: _menuAnchor!.secondaryAnchor == null
            ? null
            : _menuAnchor!.secondaryAnchor! + shift,
      ),
      buttonItems: <ContextMenuButtonItem>[
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          onPressed: () => unawaited(_copy(region)),
        ),
        if (!_delegate.selectsDocument)
          ContextMenuButtonItem(
            type: ContextMenuButtonType.selectAll,
            onPressed: () {
              region.selectAll(SelectionChangedCause.toolbar);
              _refreshVisual();
            },
          ),
      ],
    );
  }

  @override
  void dispose() {
    _handleMenu.remove();
    _magnifier.hide();
    _magnifierInfo.dispose();
    WidgetsBinding.instance.removeObserver(this);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_trackPointer);
    _edgeScroller?.dispose();
    _focusNode.removeListener(_focusChanged);
    _delegate.removeListener(_refreshVisual);
    _delegate.dispose();
    _visualRepaint.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        // SelectableRegion's overridable keyboard action must copy the full
        // document too, rather than just the currently materialized children.
        CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
          onInvoke: (intent) {
            final region = _regionKey.currentState;
            if (region != null) {
              unawaited(_copy(region));
            }
            return null;
          },
        ),
      },
      // The same platform controls and magnifier as SelectionArea. Override
      // only cancellation at the region boundary, BEFORE Flutter clears its
      // root delegate/handle owners; filtering in a child delegate is too late.
      child: _ScrollPreservingSelectionRegion(
        key: _regionKey,
        preserveGestureSelection: () =>
            _touchPointers.isNotEmpty && _focusNode.hasFocus,
        selectionControls: ReaderSelectionHandleControls(
          canStartDrag: () => !_handleDragging,
          onDragStart: _startHandle,
          onDragUpdate: _updateHandle,
          onDragEnd: _endHandle,
          delegate: switch (Theme.of(context).platform) {
            TargetPlatform.android ||
            TargetPlatform.fuchsia => materialTextSelectionHandleControls,
            TargetPlatform.iOS => cupertinoTextSelectionHandleControls,
            TargetPlatform.macOS => cupertinoDesktopTextSelectionHandleControls,
            TargetPlatform.linux ||
            TargetPlatform.windows => desktopTextSelectionHandleControls,
          },
        ),
        magnifierConfiguration: folioTextMagnifierConfiguration,
        focusNode: _focusNode,
        contextMenuBuilder: _menu,
        onSelectionChanged: _selectionChanged,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _pointerDown,
          onPointerUp: _pointerFinished,
          onPointerCancel: _pointerFinished,
          child: SelectionContainer(
            key: _containerKey,
            delegate: _delegate,
            child: NotificationListener<ScrollNotification>(
              onNotification: (_) {
                _refreshVisual();
                return false;
              },
              child: Stack(
                key: _visualKey,
                fit: StackFit.expand,
                children: <Widget>[
                  DefaultSelectionStyle.merge(
                    selectionColor: const Color(0x00000000),
                    child: TextSelectionSourceScope(
                      registry: _sourceRegistry,
                      child: widget.document.chunks.length == 1
                          ? TextSelectionSourceChunk(
                              chunk: widget.document.chunks.single,
                              isMarkdown: widget.document.isMarkdown,
                              fallback: true,
                              child: widget.child,
                            )
                          : widget.child,
                    ),
                  ),
                  IgnorePointer(
                    child: CustomPaint(
                      foregroundPainter: FolioSelectionHighlightPainter(
                        _visibleHighlightRects,
                        repaint: _visualRepaint,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectionVisualNotifier extends ChangeNotifier {
  void refresh() => notifyListeners();
}

/// Uses Flutter's selection engine, with one targeted cancellation policy.
/// A native tap collapses through edge events, and long press selects a word;
/// neither is blocked. Real focus loss must still clear the selection.
class _ScrollPreservingSelectionRegion extends SelectableRegion {
  const _ScrollPreservingSelectionRegion({
    required this.preserveGestureSelection,
    required super.selectionControls,
    required super.child,
    super.focusNode,
    super.contextMenuBuilder,
    super.magnifierConfiguration,
    super.onSelectionChanged,
    super.key,
  });

  final bool Function() preserveGestureSelection;

  @override
  SelectableRegionState createState() =>
      _ScrollPreservingSelectionRegionState();
}

class _ScrollPreservingSelectionRegionState extends SelectableRegionState {
  @override
  void clearSelection() {
    final region = widget as _ScrollPreservingSelectionRegion;
    if (!region.preserveGestureSelection()) {
      super.clearSelection();
    }
  }
}

/// This container has one stable child: Scrollable's own selection delegate.
/// Scrollable handles lazy child registration and native selection propagation;
/// the reader supplies its own edge-scroll policy through [transformEdge].
/// Track actual selection commands, not geometry notifications, so scrolling
/// and orientation changes cannot turn Select all into Copy visible text only.
class _DocumentSelectionDelegate extends StaticSelectionContainerDelegate {
  SelectionEdgeUpdateEvent Function(SelectionEdgeUpdateEvent)? transformEdge;
  void Function(SelectionEvent, SelectedContentRange?)? onSelectionEvent;
  bool selectsDocument = false;
  int revision = 0;

  void invalidate() {
    selectsDocument = false;
    revision++;
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    final before = getSelection();
    selectsDocument = event.type == SelectionEventType.selectAll;
    revision++;
    final effective = event is SelectionEdgeUpdateEvent
        ? transformEdge?.call(event) ?? event
        : event;
    final result = super.dispatchSelectionEvent(effective);
    onSelectionEvent?.call(effective, before);
    return result;
  }
}
