import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/gestures.dart' show GestureBinding, PointerEvent;
import 'package:flutter/material.dart'
    show
        ContextMenuButtonItem,
        ContextMenuButtonType,
        DefaultMaterialLocalizations,
        TextSelectionToolbarAnchors,
        TextSelectionThemeData,
        Theme,
        materialTextSelectionHandleControls;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../../shared/selection/folio_selection_toolbar.dart';
import '../../../../shared/selection/selection_magnifier.dart';
import '../../../../shared/selection/selection_visuals.dart';
import '../../../../shared/theme/folio_theme.dart';
import '../../widgets/reader_loading_view.dart';
import '../logic/pdf_document_renderer.dart';
import '../logic/pdf_reading_layout.dart';
import '../logic/pdf_selection_edge_scroller.dart';

class PdfDocumentView extends StatefulWidget {
  const PdfDocumentView({
    required this.renderer,
    required this.onContentTap,
    required this.onVerticalReadingGesture,
    super.key,
  });

  final PdfDocumentRenderer renderer;
  final VoidCallback onContentTap;
  final ValueChanged<double> onVerticalReadingGesture;

  @override
  State<PdfDocumentView> createState() => _PdfDocumentViewState();
}

class _PdfDocumentViewState extends State<PdfDocumentView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const int _renderCacheBudget = 128 * 1024 * 1024;

  final PdfViewerController _controller = PdfViewerController();
  late final PdfSelectionEdgeScroller _edgeScroller;
  late final PdfViewerParams _params;
  int? _handlePointer;
  Offset? _handlePosition;
  int _documentGeneration = 0;
  PdfDocumentRef? _activeDocumentRef;
  bool _selectingText = false;
  bool _selectionActionRunning = false;
  PdfTextSelectionRange? _selectedRange;
  final Map<int, PdfPageText> _selectedPageText = <int, PdfPageText>{};
  final Map<int, Future<PdfPageText>> _loadingSelectedPages = {};
  final Map<int, List<Rect>> _paintedSelectionRects = <int, List<Rect>>{};
  final Map<int, (Rect, Path)> _selectionPaths = {};
  final Stopwatch _hapticClock = Stopwatch()..start();
  int? _lastSelectionHaptic;
  bool _selectionRepaintScheduled = false;

  /// Identity of the range currently painted (`page#index` pairs). pdfrx
  /// rebuilds a fresh [PdfTextSelectionRange] on every read, so its value
  /// equality cannot be used to detect changes.
  String? _liveSelectionKey;
  Timer? _selectionPollTimer;

  /// Long press selects a word only after the page text is extracted, which can
  /// outlast the pointer events. Poll for a short bounded window so the
  /// highlight appears as soon as the word is selected.
  static const int _selectionPollTicks = 75;

  /// Page text is immutable and expensive to extract. Multi-page selections
  /// keep one entry per page and evict the oldest pages beyond this bound.
  static const int _pageTextCacheLimit = 24;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _edgeScroller.dispose();
    _documentGeneration++;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(
      _pointerRouterEvent,
    );
    _stopSelectionPolling();
    _liveSelectionKey = null;
    // PdfViewerController has no dispose in pdfrx 2.6.1 (owned by PdfViewer
    // while mounted): drop our selection caches so a disposed state never
    // retains page text/rects across documents.
    _selectedPageText.clear();
    _loadingSelectedPages.clear();
    _paintedSelectionRects.clear();
    _selectionPaths.clear();
    _selectedRange = null;
    super.dispose();
  }

  @override
  void didUpdateWidget(PdfDocumentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Cached page text belongs to one document. The widget carries no key, so
    // a renderer swap reuses this state and must not keep stale page text.
    if (!identical(widget.renderer, oldWidget.renderer)) {
      _resetSelectionDocument();
    }
  }

  void _resetSelectionDocument() {
    _cancelSelectionDrag();
    _documentGeneration++;
    _stopSelectionPolling();
    _liveSelectionKey = null;
    _selectedPageText.clear();
    _loadingSelectedPages.clear();
    _paintedSelectionRects.clear();
    _selectionPaths.clear();
    _selectedRange = null;
    _selectingText = false;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _edgeScroller = PdfSelectionEdgeScroller(
      vsync: this,
      controller: _controller,
      viewport: _selectionViewport,
      loadPageText: _loadSelectedPageText,
      onSelectionChanged: _applyLiveSelection,
    );
    // Global pointer routes are dispatched after the gesture recognizers, so
    // pdfrx has already moved its selection by the time this runs.
    GestureBinding.instance.pointerRouter.addGlobalRoute(_pointerRouterEvent);
    _params = PdfViewerParams(
      margin: 0,
      layoutPages: layoutPdfReadingPages,
      sizeDelegateProvider: pdfReadingSizeDelegateProvider,
      backgroundColor: appColors.background,
      pageDropShadow: const BoxShadow(
        color: Color(0x7A000000),
        blurRadius: 12,
        spreadRadius: 1,
        offset: Offset(0, 5),
      ),
      limitRenderingCache: true,
      maxImageBytesCachedOnMemory: _renderCacheBudget,
      horizontalCacheExtent: 0.35,
      // A deeper vertical cache keeps pages ahead rasterized during fast
      // flings, so quick scrolling stalls less on re-rendering.
      // NB: scrollPhysics below is intentionally untouched.
      verticalCacheExtent: 1.6,
      onePassRenderingSizeThreshold: 2400,
      textSelectionParams: PdfTextSelectionParams(
        enabled: true,
        enableSelectionHandles: true,
        showContextMenuAutomatically: true,
        onTextSelectionChange: _textSelectionChanged,
        // pdfrx debounces `onTextSelectionChange` by 300 ms, so read the live
        // range from the handle callbacks to paint the highlight while the
        // handle is still moving.
        onSelectionHandlePanStart: (anchor) {
          final position = _handlePosition;
          if (position != null) _edgeScroller.start(anchor, position);
          _applyLiveSelection();
        },
        onSelectionHandlePanUpdate: (_, _) => _applyLiveSelection(),
        onSelectionHandlePanEnd: (_) {
          final position = _handlePosition;
          if (position != null) _edgeScroller.update(position);
          _cancelSelectionDrag();
          _applyLiveSelection();
        },
        // Use the same Material handle geometry as SelectionArea in MD/TXT.
        buildSelectionHandle: (context, anchor, state) {
          final leading = anchor.type == PdfTextSelectionAnchorType.a;
          final rtl =
              anchor.direction == PdfTextDirection.rtl ||
              anchor.direction == PdfTextDirection.vrtl;
          return Listener(
            onPointerDown: (event) {
              if (_edgeScroller.dragging) _cancelSelectionDrag();
              _handlePointer = event.pointer;
              _handlePosition = event.position;
            },
            onPointerMove: (event) {
              if (event.pointer == _handlePointer) {
                _handlePosition = event.position;
              }
            },
            child: materialTextSelectionHandleControls.buildHandle(
              context,
              leading != rtl
                  ? TextSelectionHandleType.left
                  : TextSelectionHandleType.right,
              22,
            ),
          );
        },
        calcSelectionHandleOffset: (context, anchor, state) {
          if (anchor.type != PdfTextSelectionAnchorType.a) return Offset.zero;
          // pdfrx anchors the leading handle above the line. Material handles
          // have their tip at the top, so place it below the actual scaled line.
          final rect = _controller.textSelectionDelegate.doc2local.rectToLocal(
            context,
            anchor.rect,
          );
          return Offset(0, (rect?.height ?? 22) + 22);
        },
        magnifier: PdfViewerSelectionMagnifierParams(
          // Avoid repeatedly evicting the magnifier's current page image.
          maxImageBytesCachedOnMemory: 8 * 1024 * 1024,
          builder: _buildCompactMagnifier,
          getMagnifierRectForAnchor: (anchor, params, pointer) =>
              folioSelectionMagnifierSourceRect(
                focalPoint: Offset(
                  _controller.localToDocument(pointer).dx,
                  anchor.rect.center.dy,
                ),
                viewportZoom: _controller.currentZoom,
              ),
        ),
      ),
      buildContextMenu: _buildContextMenu,
      scrollPhysics: const BouncingScrollPhysics(
        decelerationRate: ScrollDecelerationRate.fast,
      ),
      scrollPhysicsScale: const BouncingScrollPhysics(
        decelerationRate: ScrollDecelerationRate.fast,
      ),
      matchTextColor: appColors.pdfSearchMatch,
      activeMatchTextColor: appColors.pdfActiveSearchMatch,
      pagePaintCallbacks: <PdfViewerPagePaintCallback>[
        _paintSelection,
        (canvas, rect, page) =>
            widget.renderer.paintSearchMatches(canvas, rect, page),
      ],
      behaviorControlParams: const PdfViewerBehaviorControlParams(
        loadPageDimensionsOnDemand: true,
        // Shorter trailing delay so pages following a fast fling become
        // available sooner instead of visibly stalling mid-scroll.
        trailingPageLoadingDelay: Duration(milliseconds: 30),
        enableLowResolutionPagePreview: true,
      ),
      onViewerReady: (document, controller) =>
          widget.renderer.attachViewer(document, controller),
      onDocumentLoadFinished: (ref, succeeded) =>
          widget.renderer.documentLoadFinished(ref, succeeded),
      onPageChanged: (page) => widget.renderer.pageChanged(page),
      onInteractionUpdate: _interactionUpdated,
      onGeneralTap: _generalTap,
      loadingBannerBuilder: (context, downloaded, total) {
        // Same unified surface as every other format: dots plus the single
        // `Opening document` line.
        return ColoredBox(
          color: appColors.background,
          child: ReaderLoadingView(
            document: widget.renderer.document,
            immediate: true,
          ),
        );
      },
      errorBannerBuilder: (context, error, stackTrace, ref) {
        return const SizedBox.shrink();
      },
    );
  }

  void _interactionUpdated(ScaleUpdateDetails details) {
    if (_selectingText || (details.scale - 1).abs() > 0.015) {
      return;
    }
    final scrollDelta = -details.focalPointDelta.dy;
    if (scrollDelta != 0) {
      widget.onVerticalReadingGesture(scrollDelta);
    }
  }

  void _textSelectionChanged(PdfTextSelection selection) {
    // Final fallback: pdfrx reports the settled selection 300 ms after the last
    // update. Live drags are applied earlier through [_applyLiveSelection].
    _applySelection(selection.textSelectionPointRange);
  }

  /// Copies the live selection range from pdfrx into our paint state.
  ///
  /// pdfrx tracks the drag/handle selection synchronously but only reports it
  /// through [PdfTextSelectionParams.onTextSelectionChange] after its 300 ms
  /// debounce, which is why the rounded highlight used to appear only once the
  /// finger was released.
  void _applyLiveSelection() {
    if (!mounted || !_controller.isReady) return;
    final delegate = _controller.textSelectionDelegate;
    _applySelection(
      delegate.hasSelectedText ? delegate.textSelectionPointRange : null,
    );
  }

  void _pointerRouterEvent(PointerEvent event) {
    // pdfrx's padded hit target extends beyond the painted handle. Remember a
    // down within that region too; the native pan-start callback still decides
    // whether this pointer is actually selecting.
    if (event is PointerDownEvent &&
        _handlePointer == null &&
        (_selectionViewport()?.inflate(48).contains(event.position) ?? false)) {
      _handlePointer = event.pointer;
      _handlePosition = event.position;
    }
    if (_handlePointer == event.pointer) {
      if (event is PointerMoveEvent) {
        _handlePosition = event.position;
        _edgeScroller.update(event.position);
      } else if (event is PointerUpEvent || event is PointerCancelEvent) {
        _cancelSelectionDrag();
      }
    } else if (event is PointerDownEvent && _edgeScroller.dragging) {
      _cancelSelectionDrag();
    }
    // Only pointer events can move a text selection.
    if (event is PointerDownEvent ||
        event is PointerMoveEvent ||
        event is PointerUpEvent ||
        event is PointerCancelEvent) {
      _applyLiveSelection();
    }
  }

  Rect? _selectionViewport() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _cancelSelectionDrag() {
    _edgeScroller.stop();
    _handlePointer = null;
    _handlePosition = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _cancelSelectionDrag();
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.state == ViewFocusState.unfocused) _cancelSelectionDrag();
  }

  static String? _selectionKey(PdfTextSelectionRange? range) {
    if (range == null) return null;
    return '${range.start.text.pageNumber}#${range.start.index}'
        '-${range.end.text.pageNumber}#${range.end.index}';
  }

  void _applySelection(PdfTextSelectionRange? range) {
    final key = _selectionKey(range);
    if (key == _liveSelectionKey) return;
    final hadSelection = _selectedRange != null;
    _liveSelectionKey = key;
    _selectedRange = range;
    _selectingText = range != null;
    _paintedSelectionRects.clear();
    _selectionPaths.clear();
    if (range == null) {
      _cancelSelectionDrag();
      if (hadSelection) _scheduleSelectionRepaint();
      return;
    }
    // Same tick as the shared selection in MD/TXT/PPTX/DOCX.
    final now = _hapticClock.elapsedMilliseconds;
    if (_lastSelectionHaptic == null || now - _lastSelectionHaptic! >= 50) {
      _lastSelectionHaptic = now;
      unawaited(HapticFeedback.selectionClick());
    }
    _scheduleSelectionRepaint();
    // Keep the page text cached across drag updates. Clearing it on every
    // change made the middle pages of a multi-page selection reload while the
    // handles moved, and a load that finished after the next update was
    // dropped, so those pages could stay unpainted for the whole drag.
    _selectedPageText[range.start.text.pageNumber] = range.start.text;
    _selectedPageText[range.end.text.pageNumber] = range.end.text;
    if (_selectedPageText.length > _pageTextCacheLimit) {
      final first = range.start.text.pageNumber;
      final last = range.end.text.pageNumber;
      _selectedPageText.removeWhere((page, _) => page < first || page > last);
      while (_selectedPageText.length > _pageTextCacheLimit) {
        _selectedPageText.remove(_selectedPageText.keys.first);
      }
    }
  }

  Future<PdfPageText> _loadSelectedPageText(PdfPage page) {
    final cached = _selectedPageText[page.pageNumber];
    if (cached != null) return Future.value(cached);
    return _loadingSelectedPages.putIfAbsent(page.pageNumber, () {
      final generation = _documentGeneration;
      return page.loadStructuredText().then(
        (loaded) {
          if (!mounted || generation != _documentGeneration) return loaded;
          _loadingSelectedPages.remove(page.pageNumber);
          _selectedPageText[page.pageNumber] = loaded;
          while (_selectedPageText.length > _pageTextCacheLimit) {
            _selectedPageText.remove(_selectedPageText.keys.first);
          }
          return loaded;
        },
        onError: (Object error, StackTrace stack) {
          if (generation == _documentGeneration) {
            _loadingSelectedPages.remove(page.pageNumber);
          }
          Error.throwWithStackTrace(error, stack);
        },
      );
    });
  }

  /// A long press picks a word only after its page text has been extracted,
  /// which may finish after the pointer routed events are over.
  void _watchLongPressSelection() {
    _selectionPollTimer?.cancel();
    if (!_controller.isReady) return;
    // A previous selection stays active until the new word is resolved, so wait
    // for the range to change rather than for any selection to exist.
    final initialKey = _liveSelectionKey;
    var ticks = 0;
    void poll(Timer _) {
      if (!mounted || !_controller.isReady) {
        _stopSelectionPolling();
        return;
      }
      final delegate = _controller.textSelectionDelegate;
      final range = delegate.hasSelectedText
          ? delegate.textSelectionPointRange
          : null;
      if (_selectionKey(range) != initialKey) {
        _applySelection(range);
        _stopSelectionPolling();
        return;
      }
      if (++ticks >= _selectionPollTicks) _stopSelectionPolling();
    }

    _selectionPollTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      poll,
    );
  }

  void _stopSelectionPolling() {
    _selectionPollTimer?.cancel();
    _selectionPollTimer = null;
  }

  /// pdfrx paints the page overlays from a page paint callback, and pages only
  /// repaint on a layout/scroll event. Repainting our own widget tree does not
  /// reach them, so the silhouette used to appear only after a small scroll.
  /// `invalidate` pushes a fresh layout event, which repaints the pages (and
  /// therefore the highlight) on the next frame.
  void _scheduleSelectionRepaint() {
    if (_selectionRepaintScheduled) return;
    _selectionRepaintScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectionRepaintScheduled = false;
      if (!mounted || !_controller.isReady) return;
      _controller.invalidate();
    });
    // A released handle may be the last event of the gesture: make sure the
    // post-frame callback actually runs instead of waiting for the next scroll.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  static Widget _buildCompactMagnifier(
    BuildContext context,
    PdfTextSelectionAnchor anchor,
    PdfViewerSelectionMagnifierParams params,
    Widget content,
    Size contentSize,
    Offset pointerPosition,
    Offset magnifierPosition,
  ) {
    return FolioSelectionMagnifierFrame(child: content);
  }

  void _paintSelection(Canvas canvas, Rect pageRect, PdfPage page) {
    final range = _selectedRange;
    if (range == null ||
        page.pageNumber < range.start.text.pageNumber ||
        page.pageNumber > range.end.text.pageNumber) {
      return;
    }
    final cachedPath = _selectionPaths[page.pageNumber];
    if (cachedPath != null && cachedPath.$1 == pageRect) {
      canvas.drawPath(cachedPath.$2, Paint()..color = appColors.selection);
      return;
    }
    var text = _selectedPageText[page.pageNumber];
    if (text == null) {
      if (!_loadingSelectedPages.containsKey(page.pageNumber)) {
        final generation = _documentGeneration;
        unawaited(
          _loadSelectedPageText(page)
              .then((loaded) {
                if (!mounted || generation != _documentGeneration) return;
                // The extracted text belongs to the page, not to one selection,
                // so it is stored even when the selection moved on meanwhile.
                final current = _selectedRange;
                if (current == null ||
                    page.pageNumber < current.start.text.pageNumber ||
                    page.pageNumber > current.end.text.pageNumber) {
                  return;
                }
                _scheduleSelectionRepaint();
              })
              .catchError((Object error) {
                debugPrint('Folio PDF selection geometry failed: $error');
              }),
        );
      }
      return;
    }
    final start = page.pageNumber == range.start.text.pageNumber
        ? range.start.index
        : 0;
    final end = page.pageNumber == range.end.text.pageNumber
        ? range.end.index + 1
        : text.fullText.length;
    if (end <= start) return;
    final selected = PdfPageTextRange(pageText: text, start: start, end: end);
    final rects = <Rect>[];
    for (final fragment in selected.enumerateFragmentBoundingRects()) {
      final rect = fragment.bounds.toRectInDocument(
        page: page,
        pageRect: pageRect,
      );
      if (!rect.isEmpty && rect.isFinite) rects.add(rect);
    }
    _paintedSelectionRects[page.pageNumber] = rects;
    final path = folioSelectionPath(
      rects,
      radius: folioPdfSelectionCornerRadius,
    );
    _selectionPaths[page.pageNumber] = (pageRect, path);
    while (_paintedSelectionRects.length > 8) {
      final oldest = _paintedSelectionRects.keys.first;
      _paintedSelectionRects.remove(oldest);
      _selectionPaths.remove(oldest);
    }
    canvas.drawPath(path, Paint()..color = appColors.selection);
  }

  Widget? _buildContextMenu(
    BuildContext context,
    PdfViewerContextMenuBuilderParams params,
  ) {
    final items = <ContextMenuButtonItem>[
      if (params.isTextSelectionEnabled &&
          params.textSelectionDelegate.isCopyAllowed &&
          params.textSelectionDelegate.hasSelectedText)
        ContextMenuButtonItem(
          onPressed: () => unawaited(
            _selectionAction(() async {
              final copied = await params.textSelectionDelegate
                  .copyTextSelection();
              if (!copied) return;
            }),
          ),
          type: ContextMenuButtonType.copy,
        ),
      if (params.isTextSelectionEnabled &&
          !params.textSelectionDelegate.isSelectingAllText)
        ContextMenuButtonItem(
          onPressed: () => unawaited(
            _selectionAction(params.textSelectionDelegate.selectAllText),
          ),
          type: ContextMenuButtonType.selectAll,
        ),
    ];
    if (items.isEmpty) {
      return null;
    }
    return PdfSelectionContextMenu(
      primaryAnchor: params.anchorA,
      secondaryAnchor: params.anchorB,
      visibleRects: _paintedSelectionRects.values
          .expand((rects) => rects)
          .map(
            (rect) => params.textSelectionDelegate.doc2local.rectToLocal(
              context,
              rect,
            ),
          )
          .whereType<Rect>()
          .toList(growable: false),
      buttonItems: items,
    );
  }

  Future<void> _selectionAction(Future<void> Function() action) async {
    if (_selectionActionRunning || !mounted) return;
    _selectionActionRunning = true;
    try {
      await action();
    } catch (error) {
      // Keep the selection available when the OS clipboard or document fails.
      debugPrint('Folio PDF selection action failed: $error');
    } finally {
      _selectionActionRunning = false;
      // Select-all updates the range asynchronously; pick it up without waiting
      // for pdfrx's debounced change callback.
      _applyLiveSelection();
    }
  }

  bool _generalTap(
    BuildContext context,
    PdfViewerController controller,
    PdfViewerGeneralTapHandlerDetails details,
  ) {
    switch (details.type) {
      case PdfViewerGeneralTapType.tap:
        if (!_selectingText) widget.onContentTap();
        // pdfrx clears the selection after this callback (on the gesture arena
        // sweep), so re-read the live range once the tap has fully resolved.
        scheduleMicrotask(_applyLiveSelection);
        return false;
      case PdfViewerGeneralTapType.doubleTap:
        unawaited(controller.zoomUp(loop: true));
        return true;
      case PdfViewerGeneralTapType.longPress:
        if (details.tapOn == PdfViewerPart.nonSelectedText) {
          _watchLongPressSelection();
        }
        return false;
      case PdfViewerGeneralTapType.secondaryTap:
        return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final documentRef = widget.renderer.documentRef;
    if (!identical(documentRef, _activeDocumentRef)) {
      _activeDocumentRef = documentRef;
      _resetSelectionDocument();
    }
    if (documentRef == null) {
      return const SizedBox.shrink();
    }
    return RepaintBoundary(
      key: const ValueKey<String>('pdf_document_view'),
      // pdfrx resolves highlight colours from Material Theme, not solely from
      // the app's TextSelectionTheme (the app itself uses WidgetsApp).
      child: Theme(
        data: Theme.of(context).copyWith(
          textSelectionTheme: TextSelectionThemeData(
            // pdfrx still paints its rectangular highlight. The page callback
            // above replaces it with the shared rounded silhouette.
            selectionColor: const Color(0x00000000),
            selectionHandleColor: appColors.selectionHandle,
            cursorColor: appColors.cursor,
          ),
        ),
        child: Focus(
          canRequestFocus: false,
          onFocusChange: (focused) {
            if (!focused) _cancelSelectionDrag();
          },
          child: PdfViewer(
            documentRef,
            controller: _controller,
            params: _params,
          ),
        ),
      ),
    );
  }
}

/// This widget MUST itself be an Align. pdfrx recognises Align/Positioned as
/// self-positioned menus; wrapping it in a StatelessWidget would make pdfrx add
/// a second Positioned + size observer around our already-positioned toolbar.
/// That feedback loop can continuously rebuild the overlay on text selection.
class PdfSelectionContextMenu extends Align {
  PdfSelectionContextMenu({
    required Offset primaryAnchor,
    required List<ContextMenuButtonItem> buttonItems,
    Offset? secondaryAnchor,
    List<Rect> visibleRects = const <Rect>[],
    super.key,
  }) : super(
         alignment: Alignment.topLeft,
         child: _PdfSelectionMenuContents(
           primaryAnchor: primaryAnchor,
           secondaryAnchor: secondaryAnchor,
           visibleRects: visibleRects,
           buttonItems: buttonItems,
         ),
       );
}

class _PdfSelectionMenuContents extends StatelessWidget {
  const _PdfSelectionMenuContents({
    required this.primaryAnchor,
    required this.secondaryAnchor,
    required this.buttonItems,
    required this.visibleRects,
  });

  final Offset primaryAnchor;
  final Offset? secondaryAnchor;
  final List<ContextMenuButtonItem> buttonItems;
  final List<Rect> visibleRects;

  @override
  Widget build(BuildContext context) {
    return Localizations.override(
      context: context,
      locale: const Locale('en'),
      delegates: const <LocalizationsDelegate<dynamic>>[
        DefaultMaterialLocalizations.delegate,
      ],
      child: FolioSelectionToolbar(
        anchors: folioVisibleSelectionAnchors(
          original: TextSelectionToolbarAnchors(
            primaryAnchor: primaryAnchor,
            secondaryAnchor: secondaryAnchor,
          ),
          viewport: Offset.zero & MediaQuery.sizeOf(context),
          visibleRects: visibleRects,
        ),
        buttonItems: buttonItems,
      ),
    );
  }
}
