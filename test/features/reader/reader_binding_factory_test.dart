import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/reader/data/document_content_source.dart';
import 'package:folio/features/reader/logic/document_renderer.dart';
import 'package:folio/features/reader/logic/reader_search_state.dart';
import 'package:folio/features/reader/text/data/text_document.dart';
import 'package:folio/features/reader/widgets/bindings/office_reader_binding.dart';
import 'package:folio/features/reader/widgets/bindings/pdf_reader_binding.dart';
import 'package:folio/features/reader/widgets/bindings/reader_binding_factory.dart';
import 'package:folio/features/reader/widgets/bindings/text_reader_binding.dart';

import '../../support/reader_stubs.dart';

void main() {
  final contentSource = MemoryDocumentContentSource(<String, Uint8List>{});

  test('factory routes each format to its dedicated binding', () {
    expect(
      createReaderBinding(
        PdfDocumentRenderer(
          document: stubEntry('a.pdf'),
          contentSource: contentSource,
        ),
      ),
      isA<PdfReaderBinding>(),
    );
    expect(
      createReaderBinding(
        WordDocumentRenderer(
          document: stubEntry('b.docx'),
          gateway: const PreparedSessionGateway(),
        ),
      ),
      isA<OfficeReaderBinding>(),
    );
    expect(
      createReaderBinding(
        PowerPointDocumentRenderer(
          document: stubEntry('c.pptx'),
          gateway: const PreparedSessionGateway(),
        ),
      ),
      isA<OfficeReaderBinding>(),
    );
    expect(
      createReaderBinding(
        TextDocumentRenderer(
          document: stubEntry('d.txt'),
          loader: TextDocumentLoader(contentSource),
        ),
      ),
      isA<TextReaderBinding>(),
    );
  });

  test('an unknown renderer is a programming error, not a silent fallback', () {
    expect(() => createReaderBinding(_AnonymousRenderer()), throwsStateError);
  });

  test('the unsupported fallback never offers seek commands', () {
    final renderer = UnsupportedDocumentRenderer(stubEntry('f.pdf'));
    final binding = createReaderBinding(renderer) as UnsupportedReaderBinding;
    addTearDown(binding.dispose);

    final navigation = binding.navigation;
    expect(navigation.snapshot.canSeek, isFalse);
    expect(navigation.snapshot.showScrubber, isFalse);
    expect(navigation.snapshot.confirmedFraction, isNull);
    expect(navigation.snapshot.kind, isNull);
    expect(navigation.snapshot.positionLabel, 'PDF');
    // The search state keeps its own unsupported marker.
    expect(
      renderer.searchState.textAvailability,
      ReaderTextAvailability.unsupported,
    );
  });

  test('the text binding owns its scroll resources and reports progress', () {
    final binding = createReaderBinding(
      TextDocumentRenderer(
        document: stubEntry('g.txt'),
        loader: TextDocumentLoader(contentSource),
      ),
    ) as TextReaderBinding;
    addTearDown(binding.dispose);

    expect(binding.navigation.snapshot.positionLabel, '0%');
    expect(binding.interactionPolicy.scrollControlsChrome, isTrue);
  });
}

/// A renderer type the factory does not know about.
class _AnonymousRenderer implements DocumentRenderer {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
