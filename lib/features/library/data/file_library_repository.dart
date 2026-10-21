import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

import '../../../shared/persistence/atomic_file.dart';

import '../../../shared/android/android_storage_gateway.dart';
import 'document_entry.dart';
import 'document_scanner.dart';
import 'library_repository.dart';

typedef CacheDirectoryProvider = Future<Directory> Function();

class FileLibraryRepository implements LibraryRepository {
  FileLibraryRepository({
    required this.storageGateway,
    this.scanner = const IsolateDocumentScanner(),
    CacheDirectoryProvider? cacheDirectoryProvider,
    DateTime Function()? now,
  }) : _cacheDirectoryProvider =
           cacheDirectoryProvider ?? getApplicationSupportDirectory,
       _now = now ?? DateTime.now;

  static const int _cacheVersion = 1;
  static const String _cacheFileName = 'library_catalog.v1.json';

  final StorageGateway storageGateway;
  final DocumentScanner scanner;
  final CacheDirectoryProvider _cacheDirectoryProvider;
  final DateTime Function() _now;
  final Map<String, DocumentEntry> _documents = <String, DocumentEntry>{};
  Future<void>? _cacheLoading;
  Future<void>? _writeQueue;
  bool _writeRequested = false;
  Object? lastCacheWriteError;
  bool _disposed = false;
  LibraryAccess _access = LibraryAccess.denied;

  @override
  Future<LibrarySnapshot> load() async {
    await _loadCachedDocuments();
    if (_disposed) {
      return _snapshot();
    }
    try {
      _access = await storageGateway.hasAllFilesAccess()
          ? LibraryAccess.granted
          : LibraryAccess.denied;
    } catch (_) {
      _access = LibraryAccess.denied;
    }
    return _snapshot();
  }

  Future<void> _loadCachedDocuments() => _cacheLoading ??= _loadCache();

  Future<void> _loadCache() async {
    final cached = await _readCache();
    if (_disposed) {
      return;
    }
    // Shared initialization prevents a concurrent intent/refresh from clearing
    // newly registered entries with a late disk snapshot.
    for (final document in cached) {
      _documents.putIfAbsent(document.id, () => document);
    }
  }

  @override
  Stream<LibrarySnapshot> refresh() async* {
    await load();
    if (_disposed) {
      return;
    }
    yield _snapshot();
    if (_access == LibraryAccess.denied) {
      return;
    }

    final roots = await storageGateway.storageRoots();
    if (roots.isEmpty) {
      throw const FileSystemException('Android returned no storage roots.');
    }

    final scannedIds = <String>{};
    var receivedComplete = false;
    final publishClock = Stopwatch()..start();
    var lastPublishedAt = -80;
    await for (final batch in scanner.scan(
      roots.map((root) => root.path).toList(growable: false),
    )) {
      if (_disposed) {
        return;
      }
      for (final scanned in batch.documents) {
        scannedIds.add(scanned.id);
        final previous = _documents[scanned.id];
        _documents[scanned.id] = scanned.copyWith(
          createdAt: previous?.createdAt ?? scanned.createdAt,
          lastOpenedAt: previous?.lastOpenedAt,
          isAvailable: true,
        );
      }
      if (batch.documents.isNotEmpty &&
          publishClock.elapsedMilliseconds - lastPublishedAt >= 80) {
        lastPublishedAt = publishClock.elapsedMilliseconds;
        yield _snapshot();
      }
      receivedComplete = receivedComplete || batch.isComplete;
    }
    if (!receivedComplete || _disposed) {
      return;
    }

    final retained = <String, DocumentEntry>{};
    for (final item in _documents.values) {
      if (item.source is UriDocumentSource || scannedIds.contains(item.id)) {
        retained[item.id] = item;
      } else if (item.lastOpenedAt != null) {
        retained[item.id] = item.copyWith(isAvailable: false);
      }
    }
    _documents
      ..clear()
      ..addAll(retained);
    await _persist();
    yield _snapshot();
  }

  @override
  Future<void> requestFullAccess() => storageGateway.openAllFilesSettings();

  @override
  Stream<DocumentEntry> get incomingDocuments async* {
    await for (final incoming in storageGateway.incomingDocuments) {
      final document = await _registerIncoming(incoming);
      if (document != null) {
        yield document;
      }
    }
  }

  @override
  Future<DocumentEntry?> consumeInitialDocument() async {
    try {
      final incoming = await storageGateway.consumeInitialDocument();
      if (incoming == null || _disposed) {
        return null;
      }
      final document = _entryFromIncoming(incoming);
      if (document == null) {
        return null;
      }
      final previous = _documents[document.id];
      final registered = document.copyWith(
        createdAt: previous?.createdAt ?? document.createdAt,
        lastOpenedAt: _now(),
        isAvailable: true,
      );
      _documents[registered.id] = registered;
      // Catalog hydration and persistence must never delay the first reader.
      // The background pass merges the disk cache before writing so a cold
      // launch cannot replace the rest of the catalog with this one entry.
      unawaited(_registerIncoming(incoming));
      return registered;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<DocumentEntry> markOpened(DocumentEntry document) async {
    await _loadCachedDocuments();
    if (_disposed) {
      return document;
    }
    final opened = (_documents[document.id] ?? document).copyWith(
      lastOpenedAt: _now(),
      isAvailable: true,
    );
    _documents[opened.id] = opened;
    await _persist();
    return opened;
  }

  @override
  Future<DocumentEntry?> recoverAccess(DocumentEntry document) async {
    if (document.source is FileDocumentSource &&
        _access == LibraryAccess.denied) {
      await requestFullAccess();
      return null;
    }
    final incoming = await storageGateway.requestDocumentAccess(
      displayName: document.name,
      mimeType: _mimeTypeFor(document.format),
    );
    if (incoming == null || _disposed) {
      return null;
    }
    final replacement = _entryFromIncoming(incoming)
        ?.copyWith(lastOpenedAt: document.lastOpenedAt ?? _now());
    if (replacement == null) {
      return null;
    }
    _documents.remove(document.id);
    _documents[replacement.id] = replacement;
    await _persist();
    return replacement;
  }

  @override
  Future<void> removeFromRecents(DocumentEntry document) async {
    await _loadCachedDocuments();
    if (_disposed) {
      return;
    }
    if (document.source is UriDocumentSource || !document.isAvailable) {
      _documents.remove(document.id);
    } else {
      _documents[document.id] = (_documents[document.id] ?? document).copyWith(
        lastOpenedAt: null,
      );
    }
    await _persist();
  }

  Future<DocumentEntry?> _registerIncoming(IncomingDocument incoming) async {
    await _loadCachedDocuments();
    if (_disposed) {
      return null;
    }
    final document = _entryFromIncoming(incoming);
    if (document == null) {
      return null;
    }
    final previous = _documents[document.id];
    final registered = document.copyWith(
      createdAt: previous?.createdAt ?? document.createdAt,
      lastOpenedAt: _now(),
      isAvailable: true,
    );
    _documents[registered.id] = registered.copyWith(
      lastOpenedAt: registered.lastOpenedAt ?? previous?.lastOpenedAt,
    );
    await _persist();
    return _documents[registered.id];
  }

  DocumentEntry? _entryFromIncoming(IncomingDocument incoming) {
    final format = DocumentFormatPresentation.fromFileName(
      incoming.displayName,
    );
    if (format == null || incoming.value.isEmpty) {
      return null;
    }
    final source = incoming.sourceType == 'file'
        ? FileDocumentSource(incoming.value)
        : UriDocumentSource(incoming.value);
    return DocumentEntry(
      id: stableDocumentId(source),
      source: source,
      name: incoming.displayName,
      format: format,
      sizeBytes: incoming.sizeBytes < 0 ? 0 : incoming.sizeBytes,
      modifiedAt: incoming.modifiedAt,
      createdAt: incoming.createdAt,
    );
  }

  LibrarySnapshot _snapshot() {
    return LibrarySnapshot(
      documents: List<DocumentEntry>.unmodifiable(_documents.values),
      access: _access,
    );
  }

  Future<List<DocumentEntry>> _readCache() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) {
        return const <DocumentEntry>[];
      }
      final contents = await file.readAsString();
      final decoded = await Isolate.run<Object?>(() => jsonDecode(contents));
      if (decoded is! Map || decoded['version'] != _cacheVersion) {
        return const <DocumentEntry>[];
      }
      final documents = decoded['documents'];
      if (documents is! List) {
        return const <DocumentEntry>[];
      }
      final restored = <DocumentEntry>[];
      for (final item in documents) {
        if (item is! Map) {
          continue;
        }
        try {
          var document = DocumentEntry.fromJson(item.cast<String, Object?>());
          if (document.source case FileDocumentSource(:final path)) {
            final legacyId = 'file:${path.replaceAll('\\', '/').toLowerCase()}';
            if (document.id == legacyId) {
              document = document.copyWith(
                id: stableDocumentId(document.source),
              );
            }
          }
          restored.add(document);
        } catch (_) {
          // One corrupt row does not invalidate the remaining cached library.
        }
      }
      return restored;
    } catch (_) {
      return const <DocumentEntry>[];
    }
  }

  /// Waits until every queued catalog write has reached disk.
  ///
  /// Background registration deliberately outlives the first reader. Tests use
  /// this hook to inspect the cache without racing that merge.
  @visibleForTesting
  Future<void> flushCacheWrites() async {
    while (true) {
      final write = _writeQueue;
      if (write == null) {
        return;
      }
      await write;
    }
  }

  Future<void> _persist() {
    _writeRequested = true;
    return _writeQueue ??= _drainWrites().whenComplete(() {
      _writeQueue = null;
      if (_writeRequested) {
        unawaited(_persist());
      }
    });
  }

  Future<void> _drainWrites() async {
    while (_writeRequested) {
      _writeRequested = false;
      try {
        final payload = <String, Object?>{
          'version': _cacheVersion,
          'documents': _documents.values
              .map((document) => document.toJson())
              .toList(growable: false),
        };
        final encoded = await Isolate.run<String>(() => jsonEncode(payload));
        await writeFileAtomically(await _cacheFile(), encoded);
        lastCacheWriteError = null;
      } catch (error) {
        // The catalog is a cache, never the document itself. Disk errors must
        // not abort a successful scan, intent or document-opening operation.
        lastCacheWriteError = error;
        debugPrint('Folio catalog cache could not be written: $error');
      }
    }
  }

  Future<File> _cacheFile() async {
    final directory = await _cacheDirectoryProvider();
    return File('${directory.path}${Platform.pathSeparator}$_cacheFileName');
  }

  @override
  void dispose() {
    _disposed = true;
  }
}

String _mimeTypeFor(DocumentFormat format) => switch (format) {
  DocumentFormat.pdf => 'application/pdf',
  DocumentFormat.docx =>
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  DocumentFormat.pptx =>
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  DocumentFormat.txt => 'text/plain',
  DocumentFormat.markdown => 'text/markdown',
};
