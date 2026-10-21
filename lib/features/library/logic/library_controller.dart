import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/document_entry.dart';
import '../data/library_repository.dart';

enum LibraryFilter { all, pdf, word, powerPoint, text }

extension LibraryFilterPresentation on LibraryFilter {
  String get label => switch (this) {
    LibraryFilter.all => 'All',
    LibraryFilter.pdf => 'PDF',
    LibraryFilter.word => 'Word',
    LibraryFilter.powerPoint => 'PPTX',
    LibraryFilter.text => 'Text',
  };

  bool accepts(DocumentFormat format) => switch (this) {
    LibraryFilter.all => true,
    LibraryFilter.pdf => format == DocumentFormat.pdf,
    LibraryFilter.word => format == DocumentFormat.docx,
    LibraryFilter.powerPoint => format == DocumentFormat.pptx,
    LibraryFilter.text =>
      format == DocumentFormat.txt || format == DocumentFormat.markdown,
  };
}

enum LibraryLoadState { loading, ready, failed }

class LibraryController extends ChangeNotifier {
  LibraryController({required this.repository});

  final LibraryRepository repository;
  List<DocumentEntry> _documents = const <DocumentEntry>[];
  LibraryLoadState _loadState = LibraryLoadState.loading;
  LibraryAccess _access = LibraryAccess.granted;
  LibraryFilter _filter = LibraryFilter.all;
  String _query = '';
  bool _disposed = false;
  bool _isRefreshing = false;
  bool _refreshFailed = false;
  DocumentEntry? _pendingDocument;
  bool _pendingDocumentIsExternal = false;
  DocumentEntry? _unavailableDocument;
  StreamSubscription<LibrarySnapshot>? _refreshSubscription;
  StreamSubscription<DocumentEntry>? _incomingSubscription;
  Completer<void>? _refreshCompleter;
  Future<void>? _loadFuture;
  Future<void>? _launchProbe;
  Future<void>? _refreshFuture;
  int _recoveryRevision = 0;

  // Build once per catalog revision, not once per getter/widget rebuild. A
  // query only filters the already sorted index; it never sorts it again.
  List<DocumentEntry>? _sorted;
  Map<String, String> _normalizedNames = const <String, String>{};
  List<DocumentEntry>? _matches;
  List<DocumentEntry>? _recent;
  List<DocumentEntry>? _regular;

  LibraryLoadState get loadState => _loadState;
  LibraryAccess get access => _access;
  LibraryFilter get filter => _filter;
  String get query => _query;
  int get totalCount => _documents.length;
  bool get isRefreshing => _isRefreshing;
  bool get refreshFailed => _refreshFailed;
  DocumentEntry? get pendingDocument => _pendingDocument;
  bool get pendingDocumentIsExternal => _pendingDocumentIsExternal;
  DocumentEntry? get unavailableDocument => _unavailableDocument;

  List<DocumentEntry> get matches {
    if (_matches case final cached?) {
      return cached;
    }
    _ensureIndex();
    final normalizedQuery = _query.trim().toLowerCase();
    return _matches = List<DocumentEntry>.unmodifiable(
      _sorted!.where(
        (document) =>
            _filter.accepts(document.format) &&
            (normalizedQuery.isEmpty ||
                _normalizedNames[document.id]!.contains(normalizedQuery)),
      ),
    );
  }

  List<DocumentEntry> get recentDocuments {
    if (_filter != LibraryFilter.all || _query.trim().isNotEmpty) {
      return const <DocumentEntry>[];
    }
    return _recent ??= _buildRecents();
  }

  List<DocumentEntry> _buildRecents() {
    final result =
        _documents.where((document) => document.lastOpenedAt != null).toList()
          ..sort((a, b) => b.lastOpenedAt!.compareTo(a.lastOpenedAt!));
    return List<DocumentEntry>.unmodifiable(result.take(10));
  }

  List<DocumentEntry> get regularDocuments {
    if (_regular case final cached?) {
      return cached;
    }
    final recentIds = recentDocuments.map((document) => document.id).toSet();
    return _regular = List<DocumentEntry>.unmodifiable(
      matches.where((document) => !recentIds.contains(document.id)),
    );
  }

  void _ensureIndex() {
    if (_sorted != null) {
      return;
    }
    _normalizedNames = <String, String>{
      for (final document in _documents)
        document.id: document.name.toLowerCase(),
    };
    _sorted = List<DocumentEntry>.of(_documents)
      ..sort((a, b) {
        final insensitive = _normalizedNames[a.id]!.compareTo(
          _normalizedNames[b.id]!,
        );
        return insensitive != 0 ? insensitive : a.name.compareTo(b.name);
      });
  }

  void _replaceDocuments(Iterable<DocumentEntry> documents) {
    _documents = List<DocumentEntry>.unmodifiable(documents);
    _sorted = null;
    _normalizedNames = const <String, String>{};
    _recent = null;
    _invalidateVisibleLists();
  }

  void _invalidateVisibleLists() {
    _matches = null;
    _regular = null;
  }

  Future<void> load() {
    if (_disposed) {
      return Future<void>.value();
    }
    return _loadFuture ??= _load().whenComplete(() => _loadFuture = null);
  }

  /// Resolves the cold-launch intent without waiting for the catalog. The app
  /// calls this before its first frame so an externally opened document can
  /// start rendering immediately; [load] joins the same future.
  Future<void> probeLaunchDocument() {
    if (_disposed) {
      return Future<void>.value();
    }
    return _launchProbe ??= _probeLaunchDocument();
  }

  Future<void> _probeLaunchDocument() async {
    try {
      final initialDocument = await repository.consumeInitialDocument();
      if (_disposed || initialDocument == null) {
        return;
      }
      _upsert(initialDocument);
      _pendingDocument = initialDocument;
      _pendingDocumentIsExternal = true;
      _notify();
    } catch (error) {
      // A failed launch intent must not hide an otherwise valid catalog.
      debugPrint('Folio launch document unavailable: $error');
    }
  }

  Future<void> _load() async {
    _loadState = LibraryLoadState.loading;
    _notify();
    try {
      await probeLaunchDocument();
      if (_disposed) {
        return;
      }
      // Subscribe before the catalog can fail: a warm intent must still reach
      // the library even when the saved catalog cannot be restored.
      _listenForIncomingDocuments();
      final snapshot = await repository.load();
      if (_disposed) {
        return;
      }
      _replaceDocuments(snapshot.documents);
      _access = snapshot.access;
      _loadState = LibraryLoadState.ready;
    } catch (error) {
      if (_disposed) {
        return;
      }
      _loadState = LibraryLoadState.failed;
      debugPrint('Folio catalog load failed: $error');
    }
    _notify();
    if (!_disposed && _loadState == LibraryLoadState.ready) {
      unawaited(refresh());
    }
  }

  Future<void> refresh() {
    if (_disposed) {
      return Future<void>.value();
    }
    // Resume/retry calls join an existing scan instead of repeatedly killing
    // and restarting the isolate, which could prevent a large scan finishing.
    return _refreshFuture ??= _refresh().whenComplete(
      () => _refreshFuture = null,
    );
  }

  Future<void> _refresh() async {
    await _loadFuture;
    if (_disposed) {
      return;
    }
    _isRefreshing = true;
    _refreshFailed = false;
    _notify();
    final completed = Completer<void>();
    _refreshCompleter = completed;
    try {
      _refreshSubscription = repository.refresh().listen(
        (snapshot) {
          if (_disposed) {
            return;
          }
          _replaceDocuments(snapshot.documents);
          _access = snapshot.access;
          _notify();
        },
        onError: (Object error, StackTrace stack) {
          if (!_disposed) {
            _refreshFailed = true;
            debugPrint('Folio catalog scan failed: $error');
            _notify();
          }
        },
        onDone: () {
          if (!completed.isCompleted) {
            completed.complete();
          }
        },
      );
      await completed.future;
    } catch (error) {
      if (!_disposed) {
        _refreshFailed = true;
        debugPrint('Folio catalog scan failed: $error');
      }
    } finally {
      _refreshSubscription = null;
      _refreshCompleter = null;
      _isRefreshing = false;
      _notify();
    }
  }

  Future<void> requestFullAccess() async {
    if (_disposed) {
      return;
    }
    try {
      await repository.requestFullAccess();
    } catch (error) {
      debugPrint('Folio storage settings unavailable: $error');
      _refreshFailed = true;
      _notify();
    }
  }

  void selectFilter(LibraryFilter value) {
    if (_disposed || _filter == value) {
      return;
    }
    _filter = value;
    _invalidateVisibleLists();
    _notify();
  }

  void updateQuery(String value) {
    if (_disposed || _query == value) {
      return;
    }
    _query = value;
    _invalidateVisibleLists();
    _notify();
  }

  Future<void> open(DocumentEntry document) async {
    final updated = await markOpened(document);
    if (updated == null || _disposed) {
      return;
    }
    _pendingDocument = updated;
    _pendingDocumentIsExternal = false;
    _notify();
  }

  /// Recording history must never prevent opening the actual document.
  Future<DocumentEntry?> markOpened(DocumentEntry document) async {
    if (_disposed) {
      return null;
    }
    if (!document.isAvailable) {
      _recoveryRevision++;
      _unavailableDocument = document;
      _notify();
      return null;
    }
    DocumentEntry updated;
    try {
      updated = await repository.markOpened(document);
    } catch (error) {
      debugPrint('Folio could not record recent document: $error');
      updated = document.copyWith(lastOpenedAt: DateTime.now());
    }
    if (_disposed) {
      return null;
    }
    _upsert(updated);
    _notify();
    return updated;
  }

  DocumentEntry? takePendingDocument() {
    final pending = _pendingDocument;
    _pendingDocument = null;
    _pendingDocumentIsExternal = false;
    return pending;
  }

  void dismissUnavailable() {
    if (_disposed || _unavailableDocument == null) {
      return;
    }
    _recoveryRevision++;
    _unavailableDocument = null;
    _notify();
  }

  Future<void> recoverUnavailable() async {
    final document = _unavailableDocument;
    if (_disposed || document == null) {
      return;
    }
    final revision = ++_recoveryRevision;
    try {
      final recovered = await repository.recoverAccess(document);
      if (_disposed || revision != _recoveryRevision) {
        return;
      }
      if (recovered != null) {
        _replaceDocuments(_documents.where((item) => item.id != document.id));
        _upsert(recovered);
        _pendingDocument = recovered;
        _pendingDocumentIsExternal = false;
      }
      _unavailableDocument = null;
      _notify();
    } catch (error) {
      debugPrint('Folio could not recover document access: $error');
    }
  }

  Future<void> removeUnavailableFromRecents() async {
    final document = _unavailableDocument;
    if (_disposed || document == null) {
      return;
    }
    final revision = ++_recoveryRevision;
    await removeFromRecents(document);
    if (!_disposed && revision == _recoveryRevision) {
      _unavailableDocument = null;
      _notify();
    }
  }

  Future<void> removeFromRecents(DocumentEntry document) async {
    if (_disposed) {
      return;
    }
    try {
      await repository.removeFromRecents(document);
    } catch (error) {
      debugPrint('Folio could not persist recent removal: $error');
    }
    if (_disposed) {
      return;
    }
    if (document.source is UriDocumentSource || !document.isAvailable) {
      _replaceDocuments(_documents.where((item) => item.id != document.id));
    } else {
      _replaceDocuments(
        _documents.map(
          (item) =>
              item.id == document.id ? item.copyWith(lastOpenedAt: null) : item,
        ),
      );
    }
    _notify();
  }

  void _listenForIncomingDocuments() {
    _incomingSubscription ??= repository.incomingDocuments.listen(
      (document) {
        if (_disposed) {
          return;
        }
        _upsert(document);
        _pendingDocument = document;
        _pendingDocumentIsExternal = true;
        _notify();
      },
      onError: (Object error, StackTrace stack) {
        debugPrint('Folio incoming document failed: $error');
      },
    );
  }

  void _upsert(DocumentEntry document) {
    final index = _documents.indexWhere((item) => item.id == document.id);
    _replaceDocuments(
      index < 0
          ? <DocumentEntry>[..._documents, document]
          : <DocumentEntry>[
              for (var i = 0; i < _documents.length; i++)
                if (i == index) document else _documents[i],
            ],
    );
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _recoveryRevision++;
    unawaited(_cancel(_refreshSubscription));
    unawaited(_cancel(_incomingSubscription));
    final pending = _refreshCompleter;
    if (pending != null && !pending.isCompleted) {
      pending.complete();
    }
    repository.dispose();
    super.dispose();
  }

  static Future<void> _cancel(StreamSubscription<Object?>? subscription) async {
    try {
      await subscription?.cancel();
    } catch (error) {
      debugPrint('Folio subscription cleanup failed: $error');
    }
  }
}
