import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../../library/data/document_entry.dart';
import '../../data/document_content_source.dart';
import '../../logic/document_renderer_contract.dart';
import '../../logic/reader_state.dart';
import '../data/text_document.dart';

class TextDocumentRenderer extends ChangeNotifier implements DocumentRenderer {
  TextDocumentRenderer({required this.document, required this.loader});

  @override
  final DocumentEntry document;
  final TextDocumentLoader loader;

  @override
  ReaderLoadState loadState = ReaderLoadState.loading;
  @override
  ReaderFailure? failure;
  TextDocument? content;
  List<ReaderSearchHit> _hits = const <ReaderSearchHit>[];
  Map<int, List<ReaderSearchHit>> _hitsByChunk =
      const <int, List<ReaderSearchHit>>{};
  @override
  String query = '';
  @override
  bool isSearching = false;
  @override
  int activeHitIndex = -1;
  int _openGeneration = 0;
  int _searchRevision = 0;
  bool _disposed = false;

  @override
  int get hitCount => _hits.length;

  List<ReaderSearchHit> get hits => _hits;

  @override
  ReaderSearchHit? get activeHit =>
      activeHitIndex < 0 || activeHitIndex >= _hits.length
      ? null
      : _hits[activeHitIndex];

  List<ReaderSearchHit> hitsForChunk(int chunkIndex) {
    return _hitsByChunk[chunkIndex] ?? const <ReaderSearchHit>[];
  }

  @override
  Future<void> open() async {
    if (_disposed) {
      return;
    }
    _searchRevision++;
    final generation = ++_openGeneration;
    loadState = ReaderLoadState.loading;
    failure = null;
    content = null;
    _clearSearch(notify: false);
    notifyListeners();
    try {
      final loaded = await loader.load(
        document,
        isCancelled: () => _disposed || generation != _openGeneration,
      );
      if (_disposed || generation != _openGeneration) {
        return;
      }
      content = loaded;
      loadState = ReaderLoadState.ready;
    } on UnsupportedTextEncodingException {
      if (_disposed || generation != _openGeneration) {
        return;
      }
      loadState = ReaderLoadState.failed;
      failure = const ReaderFailure(
        kind: ReaderFailureKind.unsupportedEncoding,
        title: 'Unsupported text encoding',
        message: 'Folio can read UTF-8 and BOM-marked UTF-16 text files.',
      );
    } on DocumentReadException catch (error) {
      if (_disposed || generation != _openGeneration) {
        return;
      }
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
          title: 'Could not open file',
          message: error.message,
          canRetry: true,
        ),
      };
    } catch (_) {
      if (_disposed || generation != _openGeneration) {
        return;
      }
      loadState = ReaderLoadState.failed;
      failure = const ReaderFailure(
        kind: ReaderFailureKind.unreadable,
        title: 'Could not open file',
        message: 'The document could not be decoded safely.',
        canRetry: true,
      );
    }
    notifyListeners();
    if (loadState == ReaderLoadState.ready && query.trim().isNotEmpty) {
      await search(query);
    }
  }

  @override
  Future<void> search(String value) async {
    if (_disposed) {
      return;
    }
    final normalized = value.trim();
    query = value;
    final loaded = content;
    final revision = ++_searchRevision;
    if (normalized.isEmpty || loaded == null) {
      _hits = const <ReaderSearchHit>[];
      _hitsByChunk = const <int, List<ReaderSearchHit>>{};
      activeHitIndex = -1;
      isSearching = false;
      notifyListeners();
      return;
    }

    _hits = const <ReaderSearchHit>[];
    _hitsByChunk = const <int, List<ReaderSearchHit>>{};
    activeHitIndex = -1;
    isSearching = true;
    notifyListeners();
    List<List<int>> rawHits;
    try {
      final starts = loaded.chunks.map((chunk) => chunk.startOffset).toList();
      // Keep only tiny documents on the UI thread. The markdown projection
      // does `codeUnits.toList + 3x RegExp + fromCharCodes` — at 16KB that
      // already drops frames on keystrokes, so anything above 4KB goes to
      // an isolate. Tiny docs stay sync to avoid isolate spawn latency.
      rawHits = loaded.text.length <= 4096
          ? _findSearchHits(loaded.text, normalized, loaded.isMarkdown, starts)
          : await Isolate.run<List<List<int>>>(
              () => _findSearchHits(
                loaded.text,
                normalized,
                loaded.isMarkdown,
                starts,
              ),
            );
    } catch (error) {
      if (!_disposed && revision == _searchRevision) {
        isSearching = false;
        notifyListeners();
      }
      debugPrint('Folio text search failed: $error');
      return;
    }
    if (_disposed || revision != _searchRevision) {
      return;
    }
    _hits = List<ReaderSearchHit>.unmodifiable(
      rawHits.map(
        (hit) => ReaderSearchHit(
          startOffset: hit[0],
          endOffset: hit[1],
          chunkIndex: hit[2],
        ),
      ),
    );
    final groupedHits = <int, List<ReaderSearchHit>>{};
    for (final hit in _hits) {
      (groupedHits[hit.chunkIndex] ??= <ReaderSearchHit>[]).add(hit);
    }
    _hitsByChunk = Map<int, List<ReaderSearchHit>>.unmodifiable(
      groupedHits.map(
        (chunkIndex, hits) => MapEntry<int, List<ReaderSearchHit>>(
          chunkIndex,
          List<ReaderSearchHit>.unmodifiable(hits),
        ),
      ),
    );
    activeHitIndex = _hits.isEmpty ? -1 : 0;
    isSearching = false;
    notifyListeners();
  }

  @override
  void showNextHit() {
    if (_disposed || _hits.isEmpty) {
      return;
    }
    activeHitIndex = (activeHitIndex + 1) % _hits.length;
    notifyListeners();
  }

  @override
  void showPreviousHit() {
    if (_disposed || _hits.isEmpty) {
      return;
    }
    activeHitIndex = (activeHitIndex - 1 + _hits.length) % _hits.length;
    notifyListeners();
  }

  void _clearSearch({required bool notify}) {
    query = '';
    isSearching = false;
    activeHitIndex = -1;
    _hits = const <ReaderSearchHit>[];
    _hitsByChunk = const <int, List<ReaderSearchHit>>{};
    if (notify) {
      notifyListeners();
    }
  }

  @override
  Future<void> close() async {
    _openGeneration += 1;
    _searchRevision += 1;
    content = null;
    _clearSearch(notify: false);
  }

  @override
  void dispose() {
    _disposed = true;
    content = null;
    _clearSearch(notify: false);
    _openGeneration += 1;
    _searchRevision += 1;
    super.dispose();
  }
}

List<List<int>> _findSearchHits(
  String source,
  String query,
  bool markdown,
  List<int> chunkStarts,
) {
  final projected = markdown ? _markdownSearchProjection(source) : source;
  final searchable = projected.toLowerCase();
  final needle = query.toLowerCase();
  if (needle.isEmpty) {
    return const <List<int>>[];
  }
  final result = <List<int>>[];
  var offset = 0;
  while (offset <= searchable.length - needle.length) {
    final match = searchable.indexOf(needle, offset);
    if (match < 0) {
      break;
    }
    result.add(<int>[
      match,
      match + needle.length,
      _chunkIndexFor(match, chunkStarts),
    ]);
    offset = match + needle.length;
  }
  return result;
}

int _chunkIndexFor(int offset, List<int> starts) {
  var low = 0;
  var high = starts.length - 1;
  while (low <= high) {
    final middle = (low + high) >> 1;
    if (starts[middle] <= offset) {
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return high.clamp(0, starts.length - 1);
}

String _markdownSearchProjection(String source) {
  final units = source.codeUnits.toList();

  void hide(int start, int end) {
    for (var index = start; index < end && index < units.length; index++) {
      if (units[index] != 0x0A && units[index] != 0x0D) {
        units[index] = 0x20;
      }
    }
  }

  for (final match in RegExp(
    r'!?\[([^\]]*)\]\(([^)]*)\)',
    multiLine: true,
  ).allMatches(source)) {
    final label = match.group(1) ?? '';
    final labelStart = source.indexOf(label, match.start);
    hide(match.start, labelStart);
    hide(labelStart + label.length, match.end);
  }
  for (final match in RegExp(
    r'^ {0,3}#{1,6}[ \t]+',
    multiLine: true,
  ).allMatches(source)) {
    hide(match.start, match.end);
  }
  for (final match in RegExp(r'[*_~`]').allMatches(source)) {
    hide(match.start, match.end);
  }
  return String.fromCharCodes(units);
}
