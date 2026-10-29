import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/reader/data/document_content_source.dart';
import 'package:folio/features/reader/logic/reader_state.dart';
import 'package:folio/features/reader/logic/unsupported_document_renderer.dart';
import 'package:folio/features/reader/text/data/text_document.dart';
import 'package:folio/features/reader/text/logic/text_document_renderer.dart';

void main() {
  DocumentEntry entry(String path, DocumentFormat format) => DocumentEntry(
    id: path,
    source: FileDocumentSource(path),
    name: 'Reader.${format.extension}',
    format: format,
    sizeBytes: 64,
    modifiedAt: DateTime.utc(2026, 9, 13),
  );

  test(
    'text renderer searches case-insensitively and wraps navigation',
    () async {
      const path = '/reader.txt';
      final source = MemoryDocumentContentSource(<String, Uint8List>{
        path: Uint8List.fromList(utf8.encode('Alpha beta ALPHA alpha.')),
      });
      final renderer = TextDocumentRenderer(
        document: entry(path, DocumentFormat.txt),
        loader: TextDocumentLoader(source),
      );
      addTearDown(renderer.dispose);

      await renderer.open();
      await renderer.search('alpha');

      expect(renderer.loadState, ReaderLoadState.ready);
      expect(renderer.hitCount, 3);
      expect(renderer.activeHitIndex, 0);
      renderer.showPreviousHit();
      expect(renderer.activeHitIndex, 2);
      renderer.showNextHit();
      expect(renderer.activeHitIndex, 0);
    },
  );

  test(
    'Markdown search ignores link destinations but finds visible labels',
    () async {
      const path = '/reader.md';
      final source = MemoryDocumentContentSource(<String, Uint8List>{
        path: Uint8List.fromList(
          utf8.encode(
            '# Notes\n\nVisit [OpenAI](https://example.com/private).',
          ),
        ),
      });
      final renderer = TextDocumentRenderer(
        document: entry(path, DocumentFormat.markdown),
        loader: TextDocumentLoader(source),
      );
      addTearDown(renderer.dispose);

      await renderer.open();
      await renderer.search('OpenAI');
      expect(renderer.hitCount, 1);

      await renderer.search('example.com');
      expect(renderer.hitCount, 0);
    },
  );

  test('Markdown search skips == highlight delimiters', () async {
    const path = '/mark-reader.md';
    final source = MemoryDocumentContentSource(<String, Uint8List>{
      path: Uint8List.fromList(utf8.encode('Plain ==highlighted== tail.')),
    });
    final renderer = TextDocumentRenderer(
      document: entry(path, DocumentFormat.markdown),
      loader: TextDocumentLoader(source),
    );
    addTearDown(renderer.dispose);

    await renderer.open();
    await renderer.search('highlighted');
    expect(renderer.hitCount, 1);

    await renderer.search('==highlighted');
    expect(renderer.hitCount, 0);
  });

  test('text renderer indexes matches by rendered chunk', () async {
    const path = '/chunked-reader.txt';
    final source = MemoryDocumentContentSource(<String, Uint8List>{
      path: Uint8List.fromList(
        utf8.encode(
          '${List<String>.filled(6000, 'x').join()}\n\nneedle needle',
        ),
      ),
    });
    final renderer = TextDocumentRenderer(
      document: entry(path, DocumentFormat.txt),
      loader: TextDocumentLoader(source),
    );
    addTearDown(renderer.dispose);

    await renderer.open();
    await renderer.search('needle');

    final activeChunk = renderer.activeHit!.chunkIndex;
    expect(renderer.hitsForChunk(activeChunk), hasLength(2));
    expect(renderer.hitsForChunk(activeChunk - 1), isEmpty);
  });

  test('unsupported stage formats expose a typed failure', () async {
    final renderer = UnsupportedDocumentRenderer(
      entry('/reader.pdf', DocumentFormat.pdf),
    );
    addTearDown(renderer.dispose);

    await renderer.open();

    expect(renderer.loadState, ReaderLoadState.failed);
    expect(renderer.failure?.kind, ReaderFailureKind.unsupportedFormat);
  });
}
