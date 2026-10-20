import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../library/data/document_entry.dart';
import '../../logic/document_renderer_contract.dart';
import '../../logic/reader_state.dart';
import '../../logic/renderer_lifecycle.dart';
import '../data/office_document_gateway.dart';

abstract class OfficeDocumentRendererBase extends ChangeNotifier
    implements DocumentRenderer {
  OfficeDocumentRendererBase({
    required this.document,
    required this.gateway,
    Duration? prepareTimeout,
    Duration? readyTimeout,
  }) : _prepareTimeout = prepareTimeout ?? defaultPrepareTimeout,
       _readyTimeout = readyTimeout ?? defaultReadyTimeout;

  /// Bounds how long the native `prepareDocument` call may take. Without
  /// this a stuck platform channel leaves the reader on "Opening
  /// document..." forever.
  static const Duration defaultPrepareTimeout = Duration(seconds: 20);

  /// Bounds how long the native WebView may take to post `ready` after the
  /// session exists. Vendor renderers can hang on specific files without
  /// ever resolving or rejecting — without this the loading overlay never
  /// goes away and retry is unreachable.
  static const Duration defaultReadyTimeout = Duration(seconds: 45);

  final Duration _prepareTimeout;
  final Duration _readyTimeout;

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
  Timer? _readyWatchdog;
  int _generation = 0;
  int _commandRevision = 0;
  bool _disposed = false;
  bool _viewReady = false;
  int _seekRevision = 0;
  bool _seekRunning = false;
  double? _pendingSeekFraction;

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
    _cancelReadyWatchdog();
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
      final pending = gateway.prepare(document);
      late final OfficeDocumentSession prepared;
      try {
        prepared = await pending.timeout(
          _prepareTimeout,
          onTimeout: () => throw const OfficeDocumentException(
            OfficeDocumentFailureKind.unreadable,
            'The Office document is taking too long to open.',
          ),
        );
      } catch (_) {
        // A native session that arrives after we already gave up must not
        // leak: close it instead of adopting it.
        unawaited(
          pending.then(
            (lateSession) => closeReaderResource(lateSession.close),
            onError: (_) {},
          ),
        );
        rethrow;
      }
      if (_disposed || generation != _generation) {
        await closeReaderResource(prepared.close);
        return;
      }
      _session = prepared;
      notifyListeners();
      _watchReady(generation, prepared.id);
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

  /// Watchdog for the native WebView `ready` event. Guarded by generation,
  /// disposal and session identity, so a stale fire is always inert. The timer
  /// is still cancelled on ready, close and dispose: a reader that opens and
  /// closes quickly must not keep a 45-second timer (and this object) alive.
  void _watchReady(int generation, String sessionId) {
    _readyWatchdog?.cancel();
    _readyWatchdog = Timer(_readyTimeout, () {
      _readyWatchdog = null;
      if (_disposed || generation != _generation) {
        return;
      }
      if (loadState == ReaderLoadState.ready) {
        return;
      }
      if (_session?.id != sessionId) {
        return;
      }
      _setFailure(
        const OfficeDocumentException(
          OfficeDocumentFailureKind.unreadable,
          'The Office renderer did not finish loading in time.',
        ),
      );
    });
  }

  void _cancelReadyWatchdog() {
    _readyWatchdog?.cancel();
    _readyWatchdog = null;
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
        _cancelReadyWatchdog();
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
  ///
  /// Platform-channel jumps coalesce like PDF seeks: only the latest
  /// fraction survives a fast drag, stale channel calls never pile up.
  Future<void> seekToFraction(double fraction) {
    final view = _view;
    if (_disposed || !_viewReady || view == null || positionCount <= 1) {
      return Future<void>.value();
    }
    final target = fraction.clamp(0.0, 1.0);
    _seekRevision++;
    if (_seekRunning) {
      _pendingSeekFraction = target;
      return Future<void>.value();
    }
    _seekRunning = true;
    var current = target;
    return _drainSeeks(view, current);
  }

  Future<void> _drainSeeks(OfficeViewCommands initialView, double first) async {
    var current = first;
    try {
      while (true) {
        final revision = _seekRevision;
        final view = _view;
        if (_disposed || !_viewReady || view == null || positionCount <= 1) {
          _pendingSeekFraction = null;
          break;
        }
        final index = (current * (positionCount - 1))
            .round()
            .clamp(0, positionCount - 1);
        final snapshot = view;
        await _runViewCommand(snapshot, () => snapshot.goToPositionInstant(index));
        if (_disposed) {
          break;
        }
        final next = _pendingSeekFraction;
        _pendingSeekFraction = null;
        if (next == null && revision == _seekRevision) {
          break;
        }
        if (next == null) {
          break;
        }
        current = next;
      }
    } finally {
      _seekRunning = false;
      final trailing = _pendingSeekFraction;
      _pendingSeekFraction = null;
      if (trailing != null && !_disposed) {
        unawaited(seekToFraction(trailing));
      }
    }
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
    _seekRevision += 1;
    _pendingSeekFraction = null;
    _cancelReadyWatchdog();
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
    _seekRevision += 1;
    _pendingSeekFraction = null;
    _cancelReadyWatchdog();
    _view = null;
    final session = _session;
    _session = null;
    if (session != null) {
      unawaited(closeReaderResource(session.close));
    }
    super.dispose();
  }
}
