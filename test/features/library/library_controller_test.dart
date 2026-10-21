import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/library/data/in_memory_library_repository.dart';
import 'package:folio/features/library/data/library_repository.dart';
import 'package:folio/features/library/logic/library_controller.dart';

void main() {
  late LibraryController controller;

  setUp(() {
    controller = LibraryController(
      repository: InMemoryLibraryRepository.demo(),
    );
  });

  tearDown(() => controller.dispose());

  test(
    'shows recent documents separately and sorts the rest by name',
    () async {
      await controller.load();

      expect(controller.recentDocuments.length, 3);
      expect(controller.recentDocuments.first.name, 'Product principles.pdf');
      expect(controller.regularDocuments.first.name, 'Annual report.pdf');
      expect(
        controller.regularDocuments.map((document) => document.id).toSet(),
        isNot(containsAll(controller.recentDocuments.map((item) => item.id))),
      );
    },
  );

  test('filters before applying case-insensitive filename search', () async {
    await controller.load();

    controller.selectFilter(LibraryFilter.powerPoint);
    expect(
      controller.regularDocuments.map((document) => document.name),
      containsAll(<String>['Launch review.pptx', 'Roadmap.pptx']),
    );

    controller.updateQuery('ROAD');
    expect(controller.regularDocuments.single.name, 'Roadmap.pptx');
    expect(controller.recentDocuments, isEmpty);
  });

  test('opening a document moves it to the front of Recent', () async {
    await controller.load();
    final document = controller.regularDocuments.first;

    await controller.open(document);

    expect(controller.recentDocuments.first.id, document.id);
  });

  test(
    'cold and warm external documents become pending open requests',
    () async {
      final cold = _entry('Cold.pdf');
      final warm = _entry('Warm.md');
      final repository = _StreamingRepository(initial: cold);
      final streamingController = LibraryController(repository: repository);
      addTearDown(streamingController.dispose);

      await streamingController.load();
      expect(streamingController.pendingDocumentIsExternal, isTrue);
      expect(streamingController.takePendingDocument()?.id, cold.id);
      expect(streamingController.pendingDocumentIsExternal, isFalse);

      repository.emit(warm);
      await Future<void>.delayed(Duration.zero);
      expect(streamingController.pendingDocumentIsExternal, isTrue);
      expect(streamingController.takePendingDocument()?.id, warm.id);
      expect(streamingController.pendingDocumentIsExternal, isFalse);
      expect(streamingController.totalCount, 2);
    },
  );

  test(
    'warm external documents still arrive when catalog load fails',
    () async {
      final repository = _StreamingRepository(loadError: true);
      final failingController = LibraryController(repository: repository);
      addTearDown(failingController.dispose);

      await failingController.load();
      expect(failingController.loadState, LibraryLoadState.failed);

      final warm = _entry('Warm after failure.txt');
      repository.emit(warm);
      await Future<void>.delayed(Duration.zero);

      expect(failingController.pendingDocumentIsExternal, isTrue);
      expect(failingController.takePendingDocument()?.id, warm.id);
    },
  );

  test('library taps are not marked as external launches', () async {
    final document = _entry('Library.pdf');
    final repository = _StreamingRepository(
      documents: <DocumentEntry>[document],
    );
    final libraryController = LibraryController(repository: repository);
    addTearDown(libraryController.dispose);
    await libraryController.load();

    await libraryController.open(document);

    expect(libraryController.pendingDocumentIsExternal, isFalse);
    expect(libraryController.takePendingDocument()?.id, document.id);
  });

  test(
    'unavailable Recent can be removed through its recovery state',
    () async {
      final missing = _entry(
        'Missing.txt',
      ).copyWith(lastOpenedAt: DateTime.utc(2026, 9, 13), isAvailable: false);
      final repository = _StreamingRepository(
        documents: <DocumentEntry>[missing],
      );
      final recoveryController = LibraryController(repository: repository);
      addTearDown(recoveryController.dispose);
      await recoveryController.load();

      await recoveryController.open(missing);
      expect(recoveryController.unavailableDocument?.id, missing.id);
      await recoveryController.removeUnavailableFromRecents();

      expect(recoveryController.unavailableDocument, isNull);
      expect(recoveryController.totalCount, 0);
    },
  );
}

DocumentEntry _entry(String name) {
  final source = UriDocumentSource('content://test/$name');
  return DocumentEntry(
    id: stableDocumentId(source),
    source: source,
    name: name,
    format: DocumentFormatPresentation.fromFileName(name)!,
    sizeBytes: 10,
    modifiedAt: DateTime.utc(2026, 9, 13),
  );
}

class _StreamingRepository implements LibraryRepository {
  _StreamingRepository({
    List<DocumentEntry> documents = const <DocumentEntry>[],
    this.initial,
    this.loadError = false,
  }) : _documents = List<DocumentEntry>.of(documents);

  final DocumentEntry? initial;
  final bool loadError;
  final StreamController<DocumentEntry> _incoming =
      StreamController<DocumentEntry>.broadcast();
  List<DocumentEntry> _documents;

  void emit(DocumentEntry document) {
    _documents = <DocumentEntry>[..._documents, document];
    _incoming.add(document);
  }

  @override
  Future<DocumentEntry?> consumeInitialDocument() async {
    if (initial != null) {
      _documents = <DocumentEntry>[..._documents, initial!];
    }
    return initial;
  }

  @override
  void dispose() {
    unawaited(_incoming.close());
  }

  @override
  Stream<DocumentEntry> get incomingDocuments => _incoming.stream;

  @override
  Future<LibrarySnapshot> load() async {
    if (loadError) {
      throw StateError('catalog unavailable');
    }
    return LibrarySnapshot(
      documents: List<DocumentEntry>.unmodifiable(_documents),
      access: LibraryAccess.granted,
    );
  }

  @override
  Future<DocumentEntry> markOpened(DocumentEntry document) async => document;

  @override
  Future<DocumentEntry?> recoverAccess(DocumentEntry document) async =>
      document.copyWith(isAvailable: true);

  @override
  Stream<LibrarySnapshot> refresh() => const Stream<LibrarySnapshot>.empty();

  @override
  Future<void> removeFromRecents(DocumentEntry document) async {
    _documents = _documents.where((item) => item.id != document.id).toList();
  }

  @override
  Future<void> requestFullAccess() async {}
}
