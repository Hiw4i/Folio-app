import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../library/data/document_entry.dart';
import '../../data/document_content_source.dart';
import '../../logic/document_renderer_contract.dart';
import '../../logic/reader_state.dart';
import '../../logic/renderer_lifecycle.dart';

class PdfDocumentRenderer extends ChangeNotifier implements DocumentRenderer {
  PdfDocumentRenderer({required this.document, required this.contentSource});

  static const int inMemoryDocumentThreshold = 1024 * 1024;

  @override
  final DocumentEntry document;
  final DocumentContentSource contentSource;

  @override
  ReaderLoadState loadState = ReaderLoadState.loading;
  @override
  ReaderFailure? failure;
  @override
  String query = '';
  @override
  bool isSearching = false;
  @override
  int activeHitIndex = -1;

  PreparedPdfSource? _preparedSource;
  PdfDocumentRef? _documentRef;
  PdfViewerController? _viewerController;
  PdfTextSearcher? _textSearcher;
  int _generation = 0;
  int _searchRevision = 0;
  int? _requestedHitIndex;
  bool _navigationRunning = false;
  bool _disposed = false;
  bool _probingText = false;
  int _textProbeRevision = 0;

  int currentPage = 1;
  int pageCount = 0;
  bool? searchableTextAvailable;

  /// Smooth (sub-page) scroll position driven by the viewer's transform.
  /// The reader scrubber listens to this instead of rebuilding on every
  /// [notifyListeners], so fast flings move only the thin track/thumb.
  final ValueNotifier<double> scrollFraction = ValueNotifier<double>(0);

  PdfDocumentRef? get documentRef => _documentRef;
  bool get sourceReady => _documentRef != null;

  /// Page-based fallback fraction for labels/seek when the viewer matrix
  /// is not available yet.
  double get pageFraction => pageCount <= 1
      ? 0
      : ((currentPage - 1) / (pageCount - 1)).clamp(0.0, 1.0);

  /// Super-fast scrub seek: jumps straight to the document offset without
  /// any animation, so dragging the scrubber never waits for rasterization
  /// of intermediate pages. Falls back to a page jump when the viewer
  /// layout is not ready yet.
  Future<void> seekToFraction(double fraction) async {
    final controller = _viewerController;
    if (_disposed || controller == null) {
      return;
    }
    final target = fraction.clamp(0.0, 1.0);
    try {
      if (controller.isReady) {
        final docHeight = controller.documentSize.height;
        final visibleHeight = controller.visibleRect.height;
        final maxScroll = docHeight - visibleHeight;
        if (maxScroll.isFinite && maxScroll > 0) {
          await controller.goToPosition(
            documentOffset: Offset(0, target * maxScroll),
            duration: Duration.zero,
          );
          return;
        }
      }
    } catch (_) {
      // A disposed viewer or a layout without dimensions: page fallback below.
    }
    if (pageCount > 1) {
      final page = (1 + (target * (pageCount - 1)).round()).clamp(
        1,
        pageCount,
      );
      try {
        await controller.goToPage(
          pageNumber: page,
          duration: Duration.zero,
        );
      } catch (_) {
        // A disposed viewer can cancel the jump; the scrub thumb stays.
      }
    }
  }

  void _onViewerMatrix() {
    final controller = _viewerController;
    if (_disposed || controller == null) {
      return;
    }
    try {
      if (!controller.isReady) {
        return;
      }
      final docHeight = controller.documentSize.height;
      final visibleHeight = controller.visibleRect.height;
      final maxScroll = docHeight - visibleHeight;
      if (!maxScroll.isFinite || maxScroll <= 0) {
        if (scrollFraction.value != 0) {
          scrollFraction.value = 0;
        }
        return;
      }
      final next = (controller.visibleRect.top / maxScroll).clamp(0.0, 1.0);
      if ((next - scrollFraction.value).abs() > 0.0005) {
        scrollFraction.value = next;
      }
    } catch (_) {
      // The viewer state can be torn down mid-fling; keep the last fraction.
    }
  }

  String get positionLabel =>
      pageCount <= 0 ? 'PDF' : '$currentPage / $pageCount';

  bool get hasNoSearchableText =>
      query.trim().isNotEmpty &&
      !isSearching &&
      searchableTextAvailable == false;

  @override
  int get hitCount => _textSearcher?.matches.length ?? 0;

  @override
  ReaderSearchHit? get activeHit => null;

  @override
  Future<void> open() async {
    if (_disposed) {
      return;
    }
    final generation = ++_generation;
    final previousSource = _preparedSource;
    _detachViewer();
    _preparedSource = null;
    _documentRef = null;
    loadState = ReaderLoadState.loading;
    failure = null;
    currentPage = 1;
    pageCount = 0;
    searchableTextAvailable = null;
    scrollFraction.value = 0;
    query = '';
    _searchRevision += 1;
    _requestedHitIndex = null;
    isSearching = false;
    activeHitIndex = -1;
    notifyListeners();
    if (previousSource != null) {
      await Future<void>.delayed(Duration.zero);
      await closeReaderResource(previousSource.close);
    }

    if (_disposed || generation != _generation) {
      return;
    }
    try {
      final prepared = await contentSource.preparePdf(document.source);
      if (_disposed || generation != _generation) {
        await closeReaderResource(prepared.close);
        return;
      }
      _preparedSource = prepared;
      _documentRef = _createDocumentRef(prepared);
      notifyListeners();
    } on DocumentReadException catch (error) {
      if (_disposed || generation != _generation) {
        return;
      }
      _setReadFailure(error);
    } catch (_) {
      if (_disposed || generation != _generation) {
        return;
      }
      loadState = ReaderLoadState.failed;
      failure = const ReaderFailure(
        kind: ReaderFailureKind.unreadable,
        title: 'Could not open PDF',
        message: 'The PDF source could not be prepared safely.',
        canRetry: true,
      );
      notifyListeners();
    }
  }

  PdfDocumentRef _createDocumentRef(PreparedPdfSource prepared) {
    final key = PdfDocumentRefKey(document.id, <Object?>[
      document.modifiedAt.millisecondsSinceEpoch,
      prepared.length,
    ]);
    return switch (prepared) {
      PreparedPdfFile(:final path) => PdfDocumentRefFile(
        path,
        key: key,
        useProgressiveLoading: true,
      ),
      PreparedPdfData(:final bytes) => PdfDocumentRefData(
        bytes,
        sourceName: document.id,
        key: key,
        maxSizeToCacheOnMemory: inMemoryDocumentThreshold,
        useProgressiveLoading: true,
      ),
      PreparedPdfRandomAccess(:final length, :final readRange) =>
        PdfDocumentRefCustom(
          fileSize: length,
          sourceName: document.id,
          key: key,
          maxSizeToCacheOnMemory: inMemoryDocumentThreshold,
          useProgressiveLoading: true,
          read: (buffer, position, size) async {
            final bytes = await readRange(position, size);
            final count = bytes.length.clamp(0, size);
            buffer.setRange(0, count, bytes);
            return count;
          },
        ),
    };
  }

  void attachViewer(
    PdfDocument openedDocument,
    PdfViewerController controller,
  ) {
    if (_disposed || !identical(controller.documentRef, _documentRef)) {
      return;
    }
    _detachViewer();
    _viewerController = controller;
    _viewerController!.addListener(_onViewerMatrix);
    _textSearcher = PdfTextSearcher(controller)..addListener(_searchChanged);
    pageCount = openedDocument.pages.length;
    currentPage = pageCount > 0
        ? (controller.pageNumber ?? 1).clamp(1, pageCount)
        : 1;
    loadState = ReaderLoadState.ready;
    failure = null;
    notifyListeners();
    if (query.trim().isNotEmpty) {
      _startTextSearch();
    }
  }

  void documentLoadFinished(PdfDocumentRef ref, bool succeeded) {
    if (_disposed || !identical(ref, _documentRef) || succeeded) {
      return;
    }
    final error = ref.resolveListenable().error;
    loadState = ReaderLoadState.failed;
    failure = error is PdfPasswordException
        ? const ReaderFailure(
            kind: ReaderFailureKind.passwordRequired,
            title: 'Password-protected PDF',
            message: 'Password entry is not included in Folio v1.',
          )
        : const ReaderFailure(
            kind: ReaderFailureKind.unreadable,
            title: 'Could not open PDF',
            message: 'The file is damaged or is not a valid PDF document.',
            canRetry: true,
          );
    notifyListeners();
  }

  void pageChanged(int? pageNumber) {
    if (_disposed ||
        pageNumber == null ||
        pageNumber == currentPage ||
        pageCount <= 0) {
      return;
    }
    currentPage = pageNumber.clamp(1, pageCount);
    notifyListeners();
  }

  void paintSearchMatches(ui.Canvas canvas, Rect pageRect, PdfPage page) {
    _textSearcher?.pageTextMatchPaintCallback(canvas, pageRect, page);
  }

  void _searchChanged() {
    final searcher = _textSearcher;
    if (_disposed || searcher == null) {
      return;
    }
    isSearching = searcher.isSearching;
    final currentIndex = searcher.currentIndex;
    activeHitIndex = currentIndex ?? activeHitIndex;
    int? firstHitToReveal;
    if (searcher.matches.isNotEmpty) {
      searchableTextAvailable = true;
      if (currentIndex == null && activeHitIndex < 0) {
        activeHitIndex = 0;
        firstHitToReveal = 0;
      }
    }
    notifyListeners();
    if (firstHitToReveal != null) {
      _requestPdfHit(firstHitToReveal, _searchRevision);
    }
    if (!searcher.isSearching &&
        query.trim().isNotEmpty &&
        searcher.matches.isEmpty &&
        searchableTextAvailable == null) {
      unawaited(_resolveTextAvailability(_generation));
    }
  }

  Future<void> _resolveTextAvailability(int generation) async {
    if (_probingText) {
      return;
    }
    final controller = _viewerController;
    final searcher = _textSearcher;
    if (controller == null || searcher == null || !controller.isReady) {
      return;
    }
    _probingText = true;
    final probeRevision = _textProbeRevision;
    try {
      final hasText = await controller.useDocument((pdf) async {
        for (final page in pdf.pages) {
          if (_disposed ||
              generation != _generation ||
              probeRevision != _textProbeRevision) {
            return null;
          }
          final pageText = await searcher.loadText(pageNumber: page.pageNumber);
          if (pageText?.fullText.trim().isNotEmpty ?? false) {
            return true;
          }
        }
        return false;
      });
      if (!_disposed &&
          generation == _generation &&
          probeRevision == _textProbeRevision &&
          hasText != null) {
        searchableTextAvailable = hasText;
        notifyListeners();
      }
    } catch (error) {
      // A released viewer or damaged text layer is not an unhandled task
      // failure, and it does not prove that the PDF contains no text.
      debugPrint('Folio PDF text availability check failed: $error');
    } finally {
      if (probeRevision == _textProbeRevision) {
        _probingText = false;
      }
    }
  }

  @override
  Future<void> search(String value) async {
    if (_disposed) {
      return;
    }
    _searchRevision += 1;
    _requestedHitIndex = null;
    query = value;
    searchableTextAvailable = value.trim().isEmpty
        ? null
        : searchableTextAvailable;
    if (value.trim().isEmpty) {
      _textSearcher?.resetTextSearch();
      isSearching = false;
      activeHitIndex = -1;
      notifyListeners();
      return;
    }
    if (_textSearcher == null) {
      notifyListeners();
      return;
    }
    _startTextSearch();
  }

  void _startTextSearch() {
    isSearching = true;
    activeHitIndex = -1;
    _textSearcher!.startTextSearch(
      query.trim(),
      caseInsensitive: true,
      goToFirstMatch: false,
      searchImmediately: true,
    );
    notifyListeners();
  }

  @override
  void showNextHit() {
    final searcher = _textSearcher;
    if (searcher == null || searcher.matches.isEmpty) {
      return;
    }
    final current = activeHitIndex < 0 ? -1 : activeHitIndex;
    final next = (current + 1) % searcher.matches.length;
    _requestPdfHit(next, _searchRevision);
  }

  @override
  void showPreviousHit() {
    final searcher = _textSearcher;
    if (searcher == null || searcher.matches.isEmpty) {
      return;
    }
    final current = activeHitIndex < 0 ? 0 : activeHitIndex;
    final previous =
        (current - 1 + searcher.matches.length) % searcher.matches.length;
    _requestPdfHit(previous, _searchRevision);
  }

  void _requestPdfHit(int index, int searchRevision) {
    final searcher = _textSearcher;
    if (searcher == null ||
        index < 0 ||
        index >= searcher.matches.length ||
        searchRevision != _searchRevision) {
      return;
    }
    activeHitIndex = index;
    _requestedHitIndex = index;
    notifyListeners();
    if (!_navigationRunning) {
      unawaited(_drainPdfNavigation(searcher, searchRevision));
    }
  }

  Future<void> _drainPdfNavigation(
    PdfTextSearcher searcher,
    int searchRevision,
  ) async {
    _navigationRunning = true;
    while (!_disposed &&
        searchRevision == _searchRevision &&
        identical(searcher, _textSearcher)) {
      final index = _requestedHitIndex;
      _requestedHitIndex = null;
      if (index == null || index < 0 || index >= searcher.matches.length) {
        break;
      }
      try {
        await searcher.goToMatchOfIndex(index);
      } catch (_) {
        // A disposed viewer or superseded search can cancel ensureVisible.
      }
      if (_requestedHitIndex == null &&
          !_disposed &&
          searchRevision == _searchRevision &&
          identical(searcher, _textSearcher)) {
        final visiblePage = _viewerController?.pageNumber;
        if (visiblePage != null && pageCount > 0) {
          currentPage = visiblePage.clamp(1, pageCount);
        }
        notifyListeners();
      }
    }
    _navigationRunning = false;
    final currentSearcher = _textSearcher;
    if (_requestedHitIndex != null && !_disposed && currentSearcher != null) {
      unawaited(_drainPdfNavigation(currentSearcher, _searchRevision));
    }
  }

  void _cancelPdfNavigation() {
    _requestedHitIndex = null;
    if (!_navigationRunning) {
      return;
    }
    // The running ensureVisible call cannot be cancelled by pdfrx. Advancing
    // the search revision makes its completion inert.
    _searchRevision += 1;
  }

  void _setReadFailure(DocumentReadException error) {
    loadState = ReaderLoadState.failed;
    failure = switch (error.kind) {
      DocumentReadFailureKind.denied => const ReaderFailure(
        kind: ReaderFailureKind.accessDenied,
        title: 'Access expired',
        message: 'Folio no longer has permission to read this file.',
        canRetry: true,
      ),
      DocumentReadFailureKind.unavailable => const ReaderFailure(
        kind: ReaderFailureKind.unavailable,
        title: 'File unavailable',
        message: 'The file may have been moved, renamed or deleted.',
        canRetry: true,
      ),
      DocumentReadFailureKind.unreadable => ReaderFailure(
        kind: ReaderFailureKind.unreadable,
        title: 'Could not open PDF',
        message: error.message,
        canRetry: true,
      ),
    };
    notifyListeners();
  }

  void _detachViewer() {
    _textProbeRevision += 1;
    _cancelPdfNavigation();
    _viewerController?.removeListener(_onViewerMatrix);
    _viewerController = null;
    _textSearcher
      ?..removeListener(_searchChanged)
      ..dispose();
    _textSearcher = null;
    _probingText = false;
  }

  @override
  Future<void> close() async {
    _generation += 1;
    _detachViewer();
    _documentRef = null;
    final source = _preparedSource;
    _preparedSource = null;
    if (source != null) {
      await Future<void>.delayed(Duration.zero);
      await closeReaderResource(source.close);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation += 1;
    _detachViewer();
    scrollFraction.dispose();
    final source = _preparedSource;
    _preparedSource = null;
    if (source != null) {
      unawaited(closeReaderResource(source.close));
    }
    super.dispose();
  }
}
