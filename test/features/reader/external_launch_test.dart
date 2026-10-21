import 'dart:async';
import 'dart:convert';

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/app/folio_app.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/library/data/in_memory_library_repository.dart';
import 'package:folio/features/library/data/library_repository.dart';
import 'package:folio/features/library/logic/library_controller.dart';
import 'package:folio/features/library/widgets/library_screen.dart';
import 'package:folio/features/reader/data/document_content_source.dart';
import 'package:folio/features/reader/widgets/reader_screen.dart';

import '../../support/memory_settings_store.dart';

void main() {
  const path = '/documents/notes.txt';
  final document = DocumentEntry(
    id: path,
    source: const FileDocumentSource(path),
    name: 'Notes.txt',
    format: DocumentFormat.txt,
    sizeBytes: 120,
    modifiedAt: DateTime.utc(2026, 9, 13),
  );

  DocumentEntry libraryDocument(String name, DocumentFormat format) {
    final source = FileDocumentSource('/library/$name');
    return DocumentEntry(
      id: source.value,
      source: source,
      name: name,
      format: format,
      sizeBytes: 100,
      modifiedAt: DateTime.utc(2026, 9, 14),
    );
  }

  Future<void> pumpApp(
    WidgetTester tester, {
    DocumentEntry? initialDocument,
    LibraryRepository? repository,
    Map<String, Uint8List>? contents,
  }) async {
    await tester.pumpWidget(
      FolioApp(
        settingsStore: MemorySettingsStore(),
        libraryRepository:
            repository ??
            InMemoryLibraryRepository(
              documents: <DocumentEntry>[document],
              initialDocument: initialDocument,
            ),
        documentContentSource: MemoryDocumentContentSource(
          contents ??
              <String, Uint8List>{
                path: Uint8List.fromList(
                  utf8.encode(
                    'Quiet text.\n\nSearch target and another target.',
                  ),
                ),
              },
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      if (find
          .byKey(const ValueKey<String>('reader_content'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }
    await tester.pumpAndSettle();
  }

  Future<void> openLibraryDocument(WidgetTester tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Notes.txt'));
    await tester.pumpAndSettle();
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      if (find
          .byKey(const ValueKey<String>('reader_content'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }
    await tester.pumpAndSettle();
  }

  testWidgets('external launch is the root route and can reveal the library', (
    tester,
  ) async {
    await pumpApp(tester, initialDocument: document);

    final reader = tester.widget<ReaderScreen>(find.byType(ReaderScreen));
    expect(reader.openedExternally, isTrue);
    expect(
      Navigator.of(tester.element(find.byType(ReaderScreen))).canPop(),
      isFalse,
    );
    expect(find.text('Folio'), findsNothing);

    await tester.longPress(
      find.byKey(const ValueKey<String>('reader_back_button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Close app'), findsOneWidget);
    expect(find.text('Return to main'), findsOneWidget);
    expect(
      tester.getCenter(find.text('Close app')).dy,
      lessThan(tester.getCenter(find.text('Return to main')).dy),
    );

    await tester.tap(find.text('Return to main'));
    await tester.pumpAndSettle();

    expect(find.byType(ReaderScreen), findsNothing);
    expect(find.text('Folio'), findsOneWidget);
    expect(find.text('Notes.txt'), findsOneWidget);
  });

  testWidgets('expanded exit actions keep their semantic tap action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpApp(tester, initialDocument: document);

    await tester.longPress(
      find.byKey(const ValueKey<String>('reader_back_button')),
    );
    await tester.pumpAndSettle();

    final close = tester.getSemantics(find.bySemanticsLabel('Close app'));
    final back = tester.getSemantics(find.bySemanticsLabel('Return to main'));
    expect(close.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(back.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    semantics.dispose();
  });

  testWidgets('library reader returns to the library', (tester) async {
    await openLibraryDocument(tester);

    final reader = tester.widget<ReaderScreen>(find.byType(ReaderScreen));
    expect(reader.openedExternally, isFalse);

    await tester.longPress(
      find.byKey(const ValueKey<String>('reader_back_button')),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getCenter(find.text('Return to main')).dy,
      lessThan(tester.getCenter(find.text('Close app')).dy),
    );

    await tester.tap(find.text('Return to main'));
    await tester.pumpAndSettle();

    expect(find.byType(ReaderScreen), findsNothing);
    expect(find.text('Folio'), findsOneWidget);
  });

  testWidgets('warm external intent replaces the open external reader', (
    tester,
  ) async {
    final second = libraryDocument('Second.txt', DocumentFormat.txt);
    final repository = _ControllableLibraryRepository(
      documents: <DocumentEntry>[document],
      initialDocument: document,
    );
    await pumpApp(
      tester,
      repository: repository,
      contents: <String, Uint8List>{
        path: Uint8List.fromList(utf8.encode('Notes.')),
        second.source.value: Uint8List.fromList(utf8.encode('Second.')),
      },
    );
    expect(repository.hasIncomingListener, isTrue);
    expect(
      tester.widget<ReaderScreen>(find.byType(ReaderScreen)).document.id,
      document.id,
    );

    repository.emit(second);
    await tester.pump();
    await tester.pumpAndSettle();

    final reader = tester.widget<ReaderScreen>(find.byType(ReaderScreen));
    expect(reader.document.id, second.id);
    expect(reader.openedExternally, isTrue);
    expect(find.text('Folio'), findsNothing);

    // A second intent for the same file must remount because the reader reads
    // its primed renderer only in initState.
    final firstElement = tester.element(find.byType(ReaderScreen));
    repository.emit(second);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      identical(firstElement, tester.element(find.byType(ReaderScreen))),
      isFalse,
    );
  });

  testWidgets('external intent waits for the in-app reader to close', (
    tester,
  ) async {
    final second = libraryDocument('Second.txt', DocumentFormat.txt);
    final repository = _ControllableLibraryRepository(
      documents: <DocumentEntry>[document],
    );
    await pumpApp(
      tester,
      repository: repository,
      contents: <String, Uint8List>{
        path: Uint8List.fromList(utf8.encode('Notes.')),
        second.source.value: Uint8List.fromList(utf8.encode('Second.')),
      },
    );

    await tester.tap(find.text('Notes.txt'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ReaderScreen>(find.byType(ReaderScreen)).openedExternally,
      isFalse,
    );

    repository.emit(second);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      tester.widget<ReaderScreen>(find.byType(ReaderScreen)).document.id,
      document.id,
    );

    await tester.tap(find.byKey(const ValueKey<String>('reader_back_button')));
    await tester.pumpAndSettle();

    final external = tester.widget<ReaderScreen>(find.byType(ReaderScreen));
    expect(external.document.id, second.id);
    expect(external.openedExternally, isTrue);
  });

  testWidgets('external detour preserves library filter, query and scroll', (
    tester,
  ) async {
    final documents = <DocumentEntry>[
      for (var index = 1; index <= 24; index++)
        libraryDocument(
          'Report ${index.toString().padLeft(2, '0')}.pptx',
          DocumentFormat.pptx,
        ),
      libraryDocument('Annual report.pdf', DocumentFormat.pdf),
    ];
    final detour = libraryDocument('Detour.txt', DocumentFormat.txt);
    final repository = _ControllableLibraryRepository(documents: documents);
    await pumpApp(
      tester,
      repository: repository,
      contents: <String, Uint8List>{
        detour.source.value: Uint8List.fromList(utf8.encode('Detour.')),
      },
    );

    await tester.tap(find.text('PPTX'));
    await tester.pumpAndSettle();
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey<String>('search_button_hit'))),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.enterText(
      find.byKey(const ValueKey<String>('search_editable')),
      'Report',
    );
    await tester.pumpAndSettle();

    ScrollableState libraryScroll() => tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('document_list')),
        matching: find.byType(Scrollable),
      ),
    );

    await tester.drag(
      find.byKey(const ValueKey<String>('document_list')),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    final scrollBefore = libraryScroll().position.pixels;
    expect(scrollBefore, greaterThan(0));

    repository.emit(detour);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      tester.widget<ReaderScreen>(find.byType(ReaderScreen)).document.id,
      detour.id,
    );

    await tester.longPress(
      find.byKey(const ValueKey<String>('reader_back_button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Return to main'));
    await tester.pumpAndSettle();

    expect(find.byType(ReaderScreen), findsNothing);
    final library = tester.widget<LibraryScreen>(find.byType(LibraryScreen));
    expect(library.active, isTrue);
    expect(library.controller.filter, LibraryFilter.powerPoint);
    expect(library.controller.query, 'Report');
    expect(libraryScroll().position.pixels, closeTo(scrollBefore, 0.5));
  });

  testWidgets('external primary action asks Android to close the app', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await pumpApp(tester, initialDocument: document);
    await tester.tap(find.byKey(const ValueKey<String>('reader_back_button')));
    await tester.pump();

    expect(
      calls.where((call) => call.method == 'SystemNavigator.pop'),
      hasLength(1),
    );
    expect(find.byType(ReaderScreen), findsOneWidget);
  });
}

class _ControllableLibraryRepository implements LibraryRepository {
  _ControllableLibraryRepository({
    List<DocumentEntry> documents = const <DocumentEntry>[],
    this.initialDocument,
  }) : _documents = List<DocumentEntry>.of(documents);

  final DocumentEntry? initialDocument;
  final List<DocumentEntry> _documents;
  final StreamController<DocumentEntry> _incoming =
      StreamController<DocumentEntry>.broadcast();
  bool _initialConsumed = false;

  bool get hasIncomingListener => _incoming.hasListener;

  void emit(DocumentEntry document) {
    final opened = document.copyWith(lastOpenedAt: DateTime.now());
    _upsert(opened);
    _incoming.add(opened);
  }

  void _upsert(DocumentEntry document) {
    final index = _documents.indexWhere((item) => item.id == document.id);
    if (index < 0) {
      _documents.add(document);
    } else {
      _documents[index] = document;
    }
  }

  @override
  Future<LibrarySnapshot> load() async {
    return LibrarySnapshot(
      documents: List<DocumentEntry>.unmodifiable(_documents),
      access: LibraryAccess.granted,
    );
  }

  @override
  Stream<LibrarySnapshot> refresh() async* {
    yield await load();
  }

  @override
  Future<void> requestFullAccess() async {}

  @override
  Stream<DocumentEntry> get incomingDocuments => _incoming.stream;

  @override
  Future<DocumentEntry?> consumeInitialDocument() async {
    if (_initialConsumed) {
      return null;
    }
    _initialConsumed = true;
    final initial = initialDocument;
    if (initial == null) {
      return null;
    }
    final document = initial.copyWith(lastOpenedAt: DateTime.now());
    _upsert(document);
    return document;
  }

  @override
  Future<DocumentEntry> markOpened(DocumentEntry document) async {
    final opened = document.copyWith(lastOpenedAt: DateTime.now());
    _upsert(opened);
    return opened;
  }

  @override
  Future<DocumentEntry?> recoverAccess(DocumentEntry document) async {
    return document.copyWith(isAvailable: true);
  }

  @override
  Future<void> removeFromRecents(DocumentEntry document) async {
    final index = _documents.indexWhere((item) => item.id == document.id);
    if (index >= 0) {
      _documents[index] = _documents[index].copyWith(lastOpenedAt: null);
    }
  }

  @override
  void dispose() {
    unawaited(_incoming.close());
  }
}
