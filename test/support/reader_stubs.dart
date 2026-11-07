import 'package:flutter/foundation.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/reader/data/document_content_source.dart';
import 'package:folio/features/reader/logic/document_renderer.dart';
import 'package:folio/features/reader/office/data/office_document_gateway.dart';
import 'package:folio/features/reader/text/data/text_document.dart';

/// Shared renderer stubs for navigation/search-state unit tests. Each stub
/// subclasses a real renderer so adapter code is exercised against the
/// production class shape, while state stays directly controllable.
final MemoryDocumentContentSource _contentSource = MemoryDocumentContentSource(
  <String, Uint8List>{},
);

DocumentEntry stubEntry(String name) {
  final source = FileDocumentSource('/documents/$name');
  return DocumentEntry(
    id: stableDocumentId(source),
    source: source,
    name: name,
    format: DocumentFormatPresentation.fromFileName(name)!,
    sizeBytes: 10,
    modifiedAt: DateTime.utc(2026, 11, 1),
  );
}

class PdfRendererStub extends PdfDocumentRenderer {
  PdfRendererStub({String name = 'stub.pdf'})
    : super(document: stubEntry(name), contentSource: _contentSource);

  bool pdfSourceReady = false;
  int stubHits = 0;
  List<double> recordedSeeks = <double>[];

  @override
  bool get sourceReady => pdfSourceReady;

  @override
  int get hitCount => stubHits;

  @override
  Future<void> seekToFraction(double fraction) async {
    recordedSeeks.add(fraction);
  }
}

class TextRendererStub extends TextDocumentRenderer {
  TextRendererStub({String name = 'stub.txt'})
    : super(
        document: stubEntry(name),
        loader: TextDocumentLoader(_contentSource),
      );

  int stubHits = 0;

  @override
  int get hitCount => stubHits;
}

class OfficeRendererStub extends OfficeDocumentRendererBase {
  OfficeRendererStub({required super.document})
    : super(gateway: const PreparedSessionGateway());

  bool officeSourceReady = false;

  @override
  bool get sourceReady => officeSourceReady;
}

/// A DOCX renderer stub that passes the binding layer's `is Word` checks.
class WordRendererStub extends WordDocumentRenderer {
  WordRendererStub({required super.document})
    : super(gateway: const PreparedSessionGateway());

  bool officeSourceReady = false;

  @override
  bool get sourceReady => officeSourceReady;
}

/// A PPTX renderer stub that passes the binding layer's `is PowerPoint` checks.
class PowerPointRendererStub extends PowerPointDocumentRenderer {
  PowerPointRendererStub({required super.document})
    : super(gateway: const PreparedSessionGateway());

  bool officeSourceReady = false;

  @override
  bool get sourceReady => officeSourceReady;
}

class PreparedSessionGateway implements OfficeDocumentGateway {
  const PreparedSessionGateway();

  @override
  Future<OfficeDocumentSession> prepare(DocumentEntry document) async =>
      OfficeDocumentSession(
        id: 'stub-${document.id}',
        format: document.format,
        sizeBytes: document.sizeBytes,
        close: () async {},
      );
}

/// A view command sink that records calls and can fail on demand.
class RecordingOfficeView implements OfficeViewCommands {
  RecordingOfficeView({this.searchError});

  final Object? searchError;
  final List<String> calls = <String>[];

  @override
  Future<void> search(String query) async {
    calls.add('search:$query');
    final error = searchError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<void> showNextHit() async => calls.add('nextHit');

  @override
  Future<void> showPreviousHit() async => calls.add('previousHit');

  @override
  Future<void> goToPosition(int zeroBasedIndex) async =>
      calls.add('goToPosition:$zeroBasedIndex');

  @override
  Future<void> goToPositionInstant(int zeroBasedIndex) async =>
      calls.add('goToPositionInstant:$zeroBasedIndex');

  @override
  Future<void> closeOverview() async => calls.add('closeOverview');
}
