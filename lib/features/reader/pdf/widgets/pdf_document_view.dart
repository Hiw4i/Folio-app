import 'dart:async';

import 'package:flutter/material.dart'
    show
        ContextMenuButtonItem,
        ContextMenuButtonType,
        DefaultMaterialLocalizations,
        TextSelectionToolbarAnchors,
        TextSelectionThemeData,
        Theme,
        materialTextSelectionHandleControls;
import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../../shared/selection/folio_selection_toolbar.dart';
import '../../../../shared/selection/selection_visuals.dart';
import '../../../../shared/theme/folio_theme.dart';
import '../../widgets/reader_loading_view.dart';
import '../logic/pdf_document_renderer.dart';
import '../logic/pdf_reading_layout.dart';

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

class _PdfDocumentViewState extends State<PdfDocumentView> {
  static const int _renderCacheBudget = 128 * 1024 * 1024;

  final PdfViewerController _controller = PdfViewerController();
  late final PdfViewerParams _params;
  bool _selectingText = false;
  bool _selectionActionRunning = false;
  int _selectionRevision = 0;
  PdfTextSelectionRange? _selectedRange;
  final Map<int, PdfPageText> _selectedPageText = <int, PdfPageText>{};
  final Set<int> _loadingSelectedPages = <int>{};
  final Map<int, List<Rect>> _paintedSelectionRects = <int, List<Rect>>{};

  @override
  void initState() {
    super.initState();
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
        // Use the same Material handle geometry as SelectionArea in MD/TXT.
        buildSelectionHandle: (context, anchor, state) {
          final leading = anchor.type == PdfTextSelectionAnchorType.a;
          final rtl =
              anchor.direction == PdfTextDirection.rtl ||
              anchor.direction == PdfTextDirection.vrtl;
          return materialTextSelectionHandleControls.buildHandle(
            context,
            leading != rtl
                ? TextSelectionHandleType.left
                : TextSelectionHandleType.right,
            22,
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
        magnifier: const PdfViewerSelectionMagnifierParams(
          // Avoid repeatedly evicting the magnifier's current page image.
          maxImageBytesCachedOnMemory: 8 * 1024 * 1024,
          builder: _buildCompactMagnifier,
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
        widget.renderer.paintSearchMatches,
      ],
      behaviorControlParams: const PdfViewerBehaviorControlParams(
        loadPageDimensionsOnDemand: true,
        // Shorter trailing delay so pages following a fast fling become
        // available sooner instead of visibly stalling mid-scroll.
        trailingPageLoadingDelay: Duration(milliseconds: 30),
        enableLowResolutionPagePreview: true,
      ),
      onViewerReady: widget.renderer.attachViewer,
      onDocumentLoadFinished: widget.renderer.documentLoadFinished,
      onPageChanged: widget.renderer.pageChanged,
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
    _selectingText = selection.hasSelectedText;
    _selectionRevision++;
    _selectedRange = selection.textSelectionPointRange;
    _selectedPageText.clear();
    _paintedSelectionRects.clear();
    final range = _selectedRange;
    if (range != null) {
      _selectedPageText[range.start.text.pageNumber] = range.start.text;
      _selectedPageText[range.end.text.pageNumber] = range.end.text;
    }
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
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x44000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SizedBox.fromSize(
          size: folioSelectionMagnifierSize,
          child: content,
        ),
      ),
    );
  }

  void _paintSelection(Canvas canvas, Rect pageRect, PdfPage page) {
    final range = _selectedRange;
    if (range == null ||
        page.pageNumber < range.start.text.pageNumber ||
        page.pageNumber > range.end.text.pageNumber) {
      return;
    }
    var text = _selectedPageText[page.pageNumber];
    if (text == null) {
      if (_loadingSelectedPages.add(page.pageNumber)) {
        final revision = _selectionRevision;
        unawaited(
          page
              .loadStructuredText()
              .then((loaded) {
                _loadingSelectedPages.remove(page.pageNumber);
                if (!mounted || revision != _selectionRevision) return;
                _selectedPageText[page.pageNumber] = loaded;
                setState(() {});
              })
              .catchError((Object error) {
                _loadingSelectedPages.remove(page.pageNumber);
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
    while (_paintedSelectionRects.length > 8) {
      _paintedSelectionRects.remove(_paintedSelectionRects.keys.first);
    }
    canvas.drawPath(
      folioSelectionPath(rects),
      Paint()..color = appColors.selection,
    );
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
        return false;
      case PdfViewerGeneralTapType.doubleTap:
        unawaited(controller.zoomUp(loop: true));
        return true;
      case PdfViewerGeneralTapType.longPress ||
          PdfViewerGeneralTapType.secondaryTap:
        return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final documentRef = widget.renderer.documentRef;
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
        child: PdfViewer(documentRef, controller: _controller, params: _params),
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
