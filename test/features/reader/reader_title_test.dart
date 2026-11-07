import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/reader/data/document_content_source.dart';
import 'package:folio/features/reader/widgets/reader_screen.dart';

Future<void> _pumpReader(WidgetTester tester, DocumentEntry document) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ReaderScreen(
        document: document,
        contentSource: MemoryDocumentContentSource(<String, Uint8List>{}),
        onRemoveFromRecents: () async {},
      ),
    ),
  );
  await tester.pump();
}

Text _titleText(WidgetTester tester) {
  return tester.widget<Text>(
    find.descendant(
      of: find.byKey(const ValueKey<String>('reader_title_glass')),
      matching: find.byType(Text),
    ),
  );
}

void main() {
  testWidgets('long file name truncates but keeps the extension', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const name =
        '(Edited) Моя психика в социальной тревоге и повседневности.pdf';
    await _pumpReader(
      tester,
      DocumentEntry(
        id: '/long.pdf',
        source: const FileDocumentSource('/long.pdf'),
        name: name,
        format: DocumentFormat.pdf,
        sizeBytes: 1024,
        modifiedAt: DateTime.utc(2026, 9, 14),
      ),
    );

    final label = _titleText(tester).data!;
    expect(label, isNot(name));
    expect(label, endsWith('...pdf'));

    // The rendered text never exceeds its tight box inside the glass pill.
    final textSize = tester.getSize(
      find.descendant(
        of: find.byKey(const ValueKey<String>('reader_title_glass')),
        matching: find.byType(Text),
      ),
    );
    final boxSize = tester.getSize(
      find.byKey(const ValueKey<String>('reader_title_text_box')),
    );
    expect(textSize.width, lessThanOrEqualTo(boxSize.width + 0.5));
  });

  testWidgets('short file name is shown in full', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpReader(
      tester,
      DocumentEntry(
        id: '/short.txt',
        source: const FileDocumentSource('/short.txt'),
        name: 'TOMATO.txt',
        format: DocumentFormat.txt,
        sizeBytes: 12,
        modifiedAt: DateTime.utc(2026, 9, 14),
      ),
    );

    expect(_titleText(tester).data, 'TOMATO.txt');
  });

  testWidgets('name without extension shows the known format', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const name =
        'A very long file name without any extension at all yes indeed';
    await _pumpReader(
      tester,
      DocumentEntry(
        id: '/noext',
        source: const FileDocumentSource('/noext'),
        name: name,
        format: DocumentFormat.txt,
        sizeBytes: 12,
        modifiedAt: DateTime.utc(2026, 9, 14),
      ),
    );

    final label = _titleText(tester).data!;
    expect(label, isNot(name));
    expect(label, endsWith('...txt'));
  });
}
