import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../library/data/document_entry.dart';
import '../../logic/document_renderer_contract.dart';
import '../../logic/reader_state.dart';
import '../../logic/renderer_lifecycle.dart';
import '../data/office_document_gateway.dart';

abstract class OfficeDocumentRendererBase extends ChangeNotifier
    implements DocumentRenderer {
  OfficeDocumentRendererBase({required this.document, required this.gateway});

  @override
  final DocumentEntry document;
  final OfficeDocumentGateway gateway;

  @override
  ReaderLoadState loadState = ReaderLoadState.loading;
  @override
  ReaderFailure? failure;
  @override
  String query = '';
  @override
  bool isSearching = false;
  @override
  int hitCount = 0;
  @override
  int activeHitIndex = -1;

  OfficeDocumentSession? _session;
  OfficeViewCommands? _view;
  int _generation = 0;
  int _commandRevision = 0;
  bool _disposed = false;
  bool _viewReady = false;

  int currentPosition = 1;
  int positionCount = 0;
  bool? searchableTextAvailable;

  OfficeDocumentSession? get session => _session;
  bool get sourceReady => _session != null;
  String get positionLabel => positionCount <= 0
      ? document.format.extension.toUpperCase()
      : '$currentPosition / $positionCount';
  bool get hasNoSearchableText =>
      query.trim().isNotEmpty &&
      !isSearching &&
      searchableTextAvailable == false;

  @override
  ReaderSearchHit? get activeHit => null;

  @override
  Future<void> open() async {
    if (_disposed) {
      return;
    }
    _commandRevision += 1;
    final generation = ++_generation;
    final previous = _session;
    _session = null;
    _view = null;
    _viewReady = false;
    loadState = ReaderLoadState.loading;
    failure = null;
    query = '';
    isSearching = false;
    hitCount = 0;
    activeHitIndex = -1;
    currentPosition = 1;
    positionCount = 0;
    searchableTextAvailable = null;
    notifyListeners();
    if (previous != null) {
      await closeReaderResource(previous.close);
    }

    if (_disposed || generation != _generation) {
      return;
    }
    try {
      final prepared = await gateway.prepare(document);
      if (_disposed || generation != _generation) {
        await closeReaderResource(prepared.close);
        return;
      }
      _session = prepared;
      notifyListeners();
    } on OfficeDocumentException catch (error) {
      if (!_disposed && generation == _generation) {
        _setFailure(error);
      }
    } catch (_) {
      if (!_disposed && generation == _generation) {
        loadState = ReaderLoadState.failed;
        failure = ReaderFailure(
          kind: ReaderFailureKind.unreadable,
          title: 'Could not open ${document.format.extension.toUpperCase()}',
          message: 'The Office renderer could not be prepared.',
          canRetry: true,
        );
        notifyListeners();
      }
    }
  }

  void attachView(OfficeViewCommands view, String sessionId) {
    if (_disposed || sessionId != _session?.id) {
      return;
    }
    _view = view;
    _viewReady = false;
  }

  void detachView(OfficeViewCommands view) {
    if (identical(_view, view)) {
      _view = null;
      _viewReady = false;
    }
  }

  void handleViewEvent(Map<Object?, Object?> event) {
    if (_disposed || _session == null) {
      return;
    }
    switch (event['type']) {
      case 'ready':
        _viewReady = true;
        loadState = ReaderLoadState.ready;
        failure = null;
        positionCount = (event['count'] as num?)?.toInt() ?? positionCount;
        searchableTextAvailable = event['hasText'] as bool?;
        currentPosition = currentPosition.clamp(
          1,
          positionCount.clamp(1, 1 << 30),
        );
        notifyListeners();
        final view = _view;
        if (query.trim().isNotEmpty && view != null) {
          unawaited(_runViewCommand(view, () => view.search(query)));
        }
      case 'position':
        final nextCount = (event['count'] as num?)?.toInt() ?? positionCount;
        final nextPosition =
            (event['current'] as num?)?.toInt() ?? currentPosition;
        if (nextCount != positionCount || nextPosition != currentPosition) {
          positionCount = nextCount;
          currentPosition = nextPosition.clamp(1, nextCount.clamp(1, 1 << 30));
          notifyListeners();
        }
      case 'search':
        isSearching = event['searching'] as bool? ?? false;
        hitCount = (event['count'] as num?)?.toInt() ?? 0;
        activeHitIndex = (event['active'] as num?)?.toInt() ?? -1;
        notifyListeners();
      case 'error':
        loadState = ReaderLoadState.failed;
        failure = ReaderFailure(
          kind: ReaderFailureKind.unreadable,
          title: 'Could not render ${document.format.extension.toUpperCase()}',
          message:
              event['message'] as String? ??
              'The Android Office renderer stopped unexpectedly.',
          canRetry: event['recoverable'] as bool? ?? true,
        );
        notifyListeners();
    }
  }

  @override
  Future<void> search(String value) async {
    if (_disposed) {
      return;
    }
    _commandRevision += 1;
    query = value;
    activeHitIndex = -1;
    hitCount = 0;
    isSearching = value.trim().isNotEmpty;
    notifyListeners();
    final view = _view;
    if (_viewReady && view != null) {
      await _runViewCommand(view, () => view.search(value));
    } else if (value.trim().isEmpty) {
      isSearching = false;
      notifyListeners();
    }
  }

  @override
  void showNextHit() {
    final view = _view;
    if (!_disposed && _viewReady && hitCount > 0 && view != null) {
      unawaited(_runViewCommand(view, view.showNextHit));
    }
  }

  @override
  void showPreviousHit() {
    final view = _view;
    if (!_disposed && _viewReady && hitCount > 0 && view != null) {
      unawaited(_runViewCommand(view, view.showPreviousHit));
    }
  }

  double get pageFraction => positionCount <= 1
      ? 0
      : ((currentPosition - 1) / (positionCount - 1)).clamp(0.0, 1.0);

  /// Super-fast scrub seek for the reader scrubber: jumps straight to the
  /// page closest to [fraction] without animation (same instant jump as
  /// the text/pdf scrubbers, no smooth-scroll acceleration).
  Future<void> seekToFraction(double fraction) {
    final view = _view;
    if (_disposed || !_viewReady || view == null || positionCount <= 1) {
      return Future<void>.value();
    }
    final index = (fraction.clamp(0.0, 1.0) * (positionCount - 1))
        .round()
        .clamp(0, positionCount - 1);
    return _runViewCommand(view, () => view.goToPositionInstant(index));
  }

  Future<void> _runViewCommand(
    OfficeViewCommands view,
    Future<void> Function() command,
  ) async {
    final revision = _commandRevision;
    try {
      await command();
    } catch (error) {
      debugPrint('Folio Office view command failed: $error');
      if (!_disposed &&
          identical(view, _view) &&
          revision == _commandRevision) {
        // Search/navigation failure must not replace a readable document
        // with an error page or leave the search indicator spinning forever.
        isSearching = false;
        notifyListeners();
      }
    }
  }

  void _setFailure(OfficeDocumentException error) {
    loadState = ReaderLoadState.failed;
    failure = switch (error.kind) {
      OfficeDocumentFailureKind.denied => const ReaderFailure(
        kind: ReaderFailureKind.accessDenied,
        title: 'Access expired',
        message: 'Folio no longer has permission to read this file.',
        canRetry: true,
      ),
      OfficeDocumentFailureKind.unavailable => const ReaderFailure(
        kind: ReaderFailureKind.unavailable,
        title: 'File unavailable',
        message: 'The file may have been moved, renamed or deleted.',
        canRetry: true,
      ),
      OfficeDocumentFailureKind.invalidArchive => ReaderFailure(
        kind: ReaderFailureKind.unreadable,
        title: 'Invalid ${document.format.extension.toUpperCase()}',
        message: error.message,
      ),
      OfficeDocumentFailureKind.unsafeArchive => ReaderFailure(
        kind: ReaderFailureKind.unreadable,
        title: 'Unsafe Office file',
        message: error.message,
      ),
      OfficeDocumentFailureKind.unreadable => ReaderFailure(
        kind: ReaderFailureKind.unreadable,
        title: 'Could not open ${document.format.extension.toUpperCase()}',
        message: error.message,
        canRetry: true,
      ),
    };
    notifyListeners();
  }

  @override
  Future<void> close() async {
    _generation += 1;
    _commandRevision += 1;
    _view = null;
    _viewReady = false;
    final session = _session;
    _session = null;
    if (session != null) {
      await closeReaderResource(session.close);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation += 1;
    _commandRevision += 1;
    _view = null;
    final session = _session;
    _session = null;
    if (session != null) {
      unawaited(closeReaderResource(session.close));
    }
    super.dispose();
  }
}
