import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/reader/logic/reader_state.dart';
import 'package:folio/features/reader/office/data/office_document_gateway.dart';
import 'package:folio/features/reader/word/logic/word_document_renderer.dart';

void main() {
  const path = '/documents/sample.docx';
  final document = DocumentEntry(
    id: path,
    source: const FileDocumentSource(path),
    name: 'Sample.docx',
    format: DocumentFormat.docx,
    sizeBytes: 2048,
    modifiedAt: DateTime.utc(2026, 9, 13),
  );

  test('Word renderer waits for native view readiness', () async {
    final gateway = _FakeOfficeGateway();
    final renderer = WordDocumentRenderer(document: document, gateway: gateway);
    addTearDown(renderer.dispose);

    await renderer.open();

    expect(renderer.sourceReady, isTrue);
    expect(renderer.loadState, ReaderLoadState.loading);
    expect(renderer.positionLabel, 'DOCX');

    final view = _FakeOfficeView();
    renderer.attachView(view, renderer.session!.id);
    renderer.handleViewEvent(<Object?, Object?>{
      'type': 'ready',
      'count': 7,
      'hasText': true,
    });

    expect(renderer.loadState, ReaderLoadState.ready);
    expect(renderer.positionLabel, '1 / 7');
    expect(renderer.searchableTextAvailable, isTrue);
  });

  test('Word renderer relays search and hit navigation', () async {
    final renderer = WordDocumentRenderer(
      document: document,
      gateway: _FakeOfficeGateway(),
    );
    addTearDown(renderer.dispose);
    await renderer.open();
    final view = _FakeOfficeView();
    renderer.attachView(view, renderer.session!.id);
    renderer.handleViewEvent(<Object?, Object?>{'type': 'ready', 'count': 2});

    await renderer.search('folio');
    expect(view.queries, <String>['folio']);
    expect(renderer.isSearching, isTrue);

    renderer.handleViewEvent(<Object?, Object?>{
      'type': 'search',
      'count': 3,
      'active': 0,
      'searching': false,
    });
    renderer.showNextHit();
    renderer.showPreviousHit();
    await Future<void>.delayed(Duration.zero);

    expect(renderer.hitCount, 3);
    expect(renderer.activeHitIndex, 0);
    expect(view.nextCount, 1);
    expect(view.previousCount, 1);
  });

  test('Word renderer preserves archive safety failures', () async {
    final renderer = WordDocumentRenderer(
      document: document,
      gateway: _FailingOfficeGateway(),
    );
    addTearDown(renderer.dispose);

    await renderer.open();

    expect(renderer.loadState, ReaderLoadState.failed);
    expect(renderer.failure?.title, 'Unsafe Office file');
    expect(renderer.failure?.canRetry, isFalse);
  });

  test('a hanging prepare fails instead of loading forever', () async {
    final renderer = WordDocumentRenderer(
      document: document,
      gateway: _HangingOfficeGateway(),
      prepareTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(renderer.dispose);

    await renderer.open();

    expect(renderer.loadState, ReaderLoadState.failed);
    expect(renderer.sourceReady, isFalse);
    expect(renderer.failure?.message, contains('taking too long'));
    expect(renderer.failure?.canRetry, isTrue);
  });

  test('a late session arriving after the timeout is closed, not leaked', () async {
    final gateway = _LateOfficeGateway();
    final renderer = WordDocumentRenderer(
      document: document,
      gateway: gateway,
      prepareTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(renderer.dispose);

    await renderer.open();
    expect(renderer.loadState, ReaderLoadState.failed);

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(gateway.closeCount, 1);
    expect(renderer.sourceReady, isFalse);
  });

  test('a prepared session without ready fails instead of loading forever', () async {
    final renderer = WordDocumentRenderer(
      document: document,
      gateway: _FakeOfficeGateway(),
      readyTimeout: const Duration(milliseconds: 80),
    );
    addTearDown(renderer.dispose);

    await renderer.open();
    expect(renderer.sourceReady, isTrue);
    expect(renderer.loadState, ReaderLoadState.loading);

    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(renderer.loadState, ReaderLoadState.failed);
    expect(renderer.failure?.message, contains('did not finish loading'));
    expect(renderer.failure?.canRetry, isTrue);
  });

  test('ready before the watchdog keeps the document open', () async {
    final renderer = WordDocumentRenderer(
      document: document,
      gateway: _FakeOfficeGateway(),
      readyTimeout: const Duration(milliseconds: 150),
    );
    addTearDown(renderer.dispose);

    await renderer.open();
    renderer.attachView(_FakeOfficeView(), renderer.session!.id);
    renderer.handleViewEvent(<Object?, Object?>{
      'type': 'ready',
      'count': 3,
      'hasText': false,
    });
    expect(renderer.loadState, ReaderLoadState.ready);

    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(renderer.loadState, ReaderLoadState.ready);
    expect(renderer.failure, isNull);
  });

  test('closing the renderer releases the native session once', () async {
    final gateway = _FakeOfficeGateway();
    final renderer = WordDocumentRenderer(document: document, gateway: gateway);
    await renderer.open();

    await renderer.close();
    renderer.dispose();

    expect(gateway.closeCount, 1);
    expect(renderer.sourceReady, isFalse);
  });

  testWidgets('dispose cancels the ready watchdog instead of leaking it', (
    tester,
  ) async {
    // testWidgets fails on any timer still pending when the test ends, so this
    // guards the 45-second watchdog against outliving a fast close.
    final renderer = WordDocumentRenderer(
      document: document,
      gateway: _FakeOfficeGateway(),
    );
    await renderer.open();
    expect(renderer.sourceReady, isTrue);

    renderer.dispose();
    await tester.pump();
  });
}

class _FakeOfficeGateway implements OfficeDocumentGateway {
  int closeCount = 0;

  @override
  Future<OfficeDocumentSession> prepare(DocumentEntry document) async {
    return OfficeDocumentSession(
      id: 'office-session',
      format: document.format,
      sizeBytes: document.sizeBytes,
      close: () async {
        closeCount += 1;
      },
    );
  }
}

class _HangingOfficeGateway implements OfficeDocumentGateway {
  @override
  Future<OfficeDocumentSession> prepare(DocumentEntry document) {
    return Completer<OfficeDocumentSession>().future;
  }
}

class _LateOfficeGateway implements OfficeDocumentGateway {
  int closeCount = 0;

  @override
  Future<OfficeDocumentSession> prepare(DocumentEntry document) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return OfficeDocumentSession(
      id: 'office-late-session',
      format: document.format,
      sizeBytes: document.sizeBytes,
      close: () async {
        closeCount += 1;
      },
    );
  }
}

class _FailingOfficeGateway implements OfficeDocumentGateway {
  @override
  Future<OfficeDocumentSession> prepare(DocumentEntry document) {
    throw const OfficeDocumentException(
      OfficeDocumentFailureKind.unsafeArchive,
      'Unsafe compression ratio.',
    );
  }
}

class _FakeOfficeView implements OfficeViewCommands {
  final List<String> queries = <String>[];
  int nextCount = 0;
  int previousCount = 0;

  @override
  Future<void> goToPosition(int zeroBasedIndex) async {}

  @override
  Future<void> goToPositionInstant(int zeroBasedIndex) async {}

  @override
  Future<void> search(String query) async {
    queries.add(query);
  }

  @override
  Future<void> showNextHit() async {
    nextCount += 1;
  }

  @override
  Future<void> showPreviousHit() async {
    previousCount += 1;
  }
}
