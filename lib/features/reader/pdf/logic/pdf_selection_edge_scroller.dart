import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../logic/selection_edge_scroller.dart';

/// Extends a held PDF handle after each viewport transform. pdfrx updates its
/// native handles only on pointer moves, so moving the viewport alone cannot
/// advance a stationary selection. All geometry stays in document coordinates.
class PdfSelectionEdgeScroller {
  PdfSelectionEdgeScroller({
    required TickerProvider vsync,
    required this._controller,
    required this._viewport,
    required this._loadPageText,
    required this._onSelectionChanged,
  }) {
    _driver = SelectionEdgeScrollDriver(
      vsync: vsync,
      target: _target,
      onScrolled: () {
        _hasScrolled = true;
        _extendSelection();
      },
    );
  }

  final PdfViewerController _controller;
  final Rect? Function() _viewport;
  final Future<PdfPageText> Function(PdfPage) _loadPageText;
  final VoidCallback _onSelectionChanged;
  late final SelectionEdgeScrollDriver _driver;
  final Map<int, PdfPageText> _text = {};
  final Map<int, (Rect, List<Rect>)> _geometry = {};
  final Set<int> _loading = {};
  final Set<int> _failed = {};
  PdfTextSelectionPoint? _fixed;
  Offset? _globalPosition;
  Offset _handleOffset = Offset.zero;
  int _generation = 0;
  bool _hasScrolled = false;
  bool _disposed = false;

  bool get dragging => _fixed != null;

  void start(PdfTextSelectionAnchor anchor, Offset globalPosition) {
    stop();
    if (_disposed || !_controller.isReady) return;
    final range = _controller.textSelectionDelegate.textSelectionPointRange;
    final point = _controller.globalToDocument(globalPosition);
    if (range == null || point == null) return;
    _fixed = anchor.type == PdfTextSelectionAnchorType.a
        ? range.end
        : range.start;
    _handleOffset = anchor.rect.center - point;
    update(globalPosition);
  }

  void update(Offset globalPosition) {
    if (_disposed || !dragging) return;
    _globalPosition = globalPosition;
    _driver.update(globalPosition);
    // Once transforms have moved the drag, use the same document hit test on
    // subsequent moves too. The native handle's original pan anchor is stale.
    if (_hasScrolled) _extendSelection();
  }

  void stop() {
    _driver.stop();
    _generation++;
    _fixed = null;
    _globalPosition = null;
    _hasScrolled = false;
    _text.clear();
    _geometry.clear();
    _loading.clear();
    _failed.clear();
  }

  void dispose() {
    if (_disposed) return;
    stop();
    _disposed = true;
    _driver.dispose();
  }

  SelectionScrollTarget? _target() {
    final viewport = _viewport();
    if (_disposed || !dragging || !_controller.isReady || viewport == null) {
      return null;
    }
    final zoom = _controller.currentZoom;
    final height = _controller.documentSize.height * zoom;
    if (!zoom.isFinite || zoom <= 0 || !height.isFinite) return null;
    return SelectionScrollTarget(
      identity: _controller,
      viewport: viewport,
      pixels: -_controller.value.storage[13],
      minExtent: 0,
      maxExtent: height - _controller.viewSize.height,
      jumpTo: (offset) {
        final matrix = Matrix4.copy(_controller.value);
        matrix.storage[13] = -offset;
        // The public setter clamps to pdfrx's real boundaries, preserving zoom
        // and horizontal pan without starting an animation on every frame.
        _controller.value = matrix;
      },
    );
  }

  void _extendSelection() {
    final fixed = _fixed;
    final global = _globalPosition;
    final viewport = _viewport();
    if (_disposed ||
        fixed == null ||
        global == null ||
        viewport == null ||
        !viewport.isFinite ||
        viewport.isEmpty ||
        !_controller.isReady) {
      return;
    }
    final clipped = Offset(
      global.dx.clamp(viewport.left, viewport.right),
      global.dy.clamp(viewport.top, viewport.bottom),
    );
    final pointer = _controller.globalToDocument(clipped);
    if (pointer == null) return;
    final point = pointer + _handleOffset;
    final rects = _controller.layout.pageLayouts;
    if (rects.isEmpty) return;
    // Reading layout is one vertical column. Binary lookup avoids a scan of
    // every page on every frame in long documents; gaps use the nearest page.
    var low = 0;
    var high = rects.length - 1;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (rects[middle].bottom < point.dy) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    var pageIndex = low;
    if (pageIndex > 0 &&
        point.dy < rects[pageIndex].top &&
        point.dy - rects[pageIndex - 1].bottom <
            rects[pageIndex].top - point.dy) {
      pageIndex--;
    }
    final page = _controller.pages[pageIndex];
    final pageNumber = page.pageNumber;
    final text = _text[pageNumber];
    if (text == null) {
      if (_failed.contains(pageNumber) ||
          _loading.isNotEmpty ||
          !_loading.add(pageNumber)) {
        return;
      }
      final generation = _generation;
      unawaited(
        Future.sync(() => _loadPageText(page))
            .then((loaded) {
              if (_disposed || generation != _generation) return;
              _loading.remove(pageNumber);
              _text[pageNumber] = loaded;
              while (_text.length > 3) {
                final oldest = _text.keys.first;
                _text.remove(oldest);
                _geometry.remove(oldest);
              }
              // Re-evaluate the latest position, never the one that started a load.
              _extendSelection();
            })
            .catchError((Object error) {
              if (_disposed || generation != _generation) return;
              _loading.remove(pageNumber);
              _failed.add(pageNumber);
              debugPrint('Folio PDF edge selection text failed: $error');
            }),
      );
      return;
    }
    final pageRect = rects[pageIndex];
    var geometry = _geometry[pageNumber];
    if (geometry == null || geometry.$1 != pageRect) {
      geometry = (
        pageRect,
        text.charRects
            .map(
              (rect) => rect.toRectInDocument(page: page, pageRect: pageRect),
            )
            .toList(growable: false),
      );
      _geometry[pageNumber] = geometry;
    }
    final characters = geometry.$2;
    var nearest = -1;
    var distance = double.infinity;
    for (var index = 0; index < characters.length; index++) {
      final rect = characters[index];
      if (!rect.isFinite || rect.isEmpty) continue;
      final dx = point.dx - point.dx.clamp(rect.left, rect.right);
      final dy = point.dy - point.dy.clamp(rect.top, rect.bottom);
      final candidate = dx * dx + dy * dy;
      if (candidate < distance) {
        nearest = index;
        distance = candidate;
        if (candidate == 0) break;
      }
    }
    if (nearest < 0) return;
    final next = PdfTextSelectionRange.fromPoints(
      fixed,
      PdfTextSelectionPoint(text, nearest),
    );
    final delegate = _controller.textSelectionDelegate;
    final current = delegate.textSelectionPointRange;
    if (current?.start == next.start && current?.end == next.end) return;
    unawaited(delegate.setTextSelectionPointRange(next));
    _onSelectionChanged();
  }
}
