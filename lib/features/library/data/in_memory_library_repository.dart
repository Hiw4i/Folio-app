import 'document_entry.dart';
import 'library_repository.dart';

class InMemoryLibraryRepository implements LibraryRepository {
  InMemoryLibraryRepository({
    required List<DocumentEntry> documents,
    this.access = LibraryAccess.granted,
    this.initialDocument,
  }) : _documents = List<DocumentEntry>.of(documents);

  factory InMemoryLibraryRepository.demo() {
    final now = DateTime(2026, 9, 12, 10, 30);
    DocumentEntry item(
      String name,
      int size,
      int modifiedDaysAgo, {
      int? openedMinutesAgo,
    }) {
      final format = DocumentFormatPresentation.fromFileName(name)!;
      final modifiedAt = now.subtract(Duration(days: modifiedDaysAgo));
      return DocumentEntry(
        id: name.toLowerCase(),
        source: FileDocumentSource('/storage/emulated/0/Documents/$name'),
        name: name,
        format: format,
        sizeBytes: size,
        modifiedAt: modifiedAt,
        createdAt: modifiedAt.subtract(const Duration(days: 30)),
        lastOpenedAt: openedMinutesAgo == null
            ? null
            : now.subtract(Duration(minutes: openedMinutesAgo)),
      );
    }

    return InMemoryLibraryRepository(
      documents: <DocumentEntry>[
        item('Product principles.pdf', 2400000, 1, openedMinutesAgo: 8),
        item('Quiet interface.docx', 814000, 3, openedMinutesAgo: 42),
        item('Launch review.pptx', 9100000, 0, openedMinutesAgo: 180),
        item('Reading list.md', 18400, 2),
        item('Release notes.txt', 7200, 4),
        item('Annual report.pdf', 12800000, 12),
        item('Brand language.docx', 3600000, 8),
        item('Field notes.md', 42700, 7),
        item('Research summary.pdf', 5900000, 16),
        item('Roadmap.pptx', 6800000, 5),
        item('Talk transcript.txt', 156000, 9),
      ],
    );
  }

  final LibraryAccess access;
  final DocumentEntry? initialDocument;
  final List<DocumentEntry> _documents;
  bool _initialConsumed = false;

  @override
  Future<LibrarySnapshot> load() async {
    return LibrarySnapshot(
      documents: List<DocumentEntry>.unmodifiable(_documents),
      access: access,
    );
  }

  @override
  Stream<LibrarySnapshot> refresh() async* {
    yield await load();
  }

  @override
  Future<void> requestFullAccess() async {}

  @override
  Stream<DocumentEntry> get incomingDocuments => const Stream.empty();

  @override
  Future<DocumentEntry?> consumeInitialDocument() async {
    if (_initialConsumed) {
      return null;
    }
    _initialConsumed = true;
    final document = initialDocument;
    if (document == null) {
      return null;
    }
    final index = _documents.indexWhere((item) => item.id == document.id);
    if (index < 0) {
      _documents.add(document);
    } else {
      _documents[index] = document;
    }
    return document;
  }

  @override
  Future<DocumentEntry> markOpened(DocumentEntry document) async {
    final opened = document.copyWith(lastOpenedAt: DateTime.now());
    final index = _documents.indexWhere((item) => item.id == document.id);
    if (index >= 0) {
      _documents[index] = opened;
    }
    return opened;
  }

  @override
  Future<DocumentEntry?> recoverAccess(DocumentEntry document) async {
    final recovered = document.copyWith(isAvailable: true);
    final index = _documents.indexWhere((item) => item.id == document.id);
    if (index >= 0) {
      _documents[index] = recovered;
    }
    return recovered;
  }

  @override
  Future<void> removeFromRecents(DocumentEntry document) async {
    final index = _documents.indexWhere((item) => item.id == document.id);
    if (index >= 0) {
      _documents[index] = _documents[index].copyWith(lastOpenedAt: null);
    }
  }

  @override
  void dispose() {}
}
