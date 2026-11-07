import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/reader/widgets/file_info_sheet.dart';
import 'package:folio/shared/widgets/folio_sheet_content.dart';

void main() {
  for (final format in DocumentFormat.values) {
    testWidgets('shows all metadata for ${format.name} without opening a file', (
      tester,
    ) async {
      final document = DocumentEntry(
        id: 'metadata-only',
        source: const UriDocumentSource('content://documents/inaccessible'),
        name: 'Example.${format.extension}',
        format: format,
        sizeBytes: 120,
        createdAt: DateTime(2026, 9, 10),
        modifiedAt: DateTime(2026, 9, 13),
      );
      await _pumpSheet(tester, document);
      expect(find.byType(FolioSheetContent), findsOneWidget);
      expect(find.text('File Info'), findsOneWidget);
      expect(find.text(document.name), findsOneWidget);
      expect(find.text(format.extension.toUpperCase()), findsOneWidget);
      expect(find.text('120 B'), findsOneWidget);
      expect(find.text('Created'), findsOneWidget);
      expect(find.text('Modified'), findsOneWidget);
      expect(find.text('Sep 10, 2026'), findsOneWidget);
      expect(find.text('Sep 13, 2026'), findsOneWidget);
      // Details and dates live in separate cards with their own headers.
      expect(find.text('Details'), findsOneWidget);
      expect(find.text('Dates'), findsOneWidget);
      expect(find.byType(FolioSheetCard), findsNWidgets(2));
      final headers = tester
          .widgetList<FolioSheetSectionHeader>(
            find.byType(FolioSheetSectionHeader),
          )
          .toList(growable: false);
      expect(headers, hasLength(2));
      if (format.iconPath != null) {
        expect(headers.first.iconPath, format.iconPath);
      } else {
        expect(headers.first.icon, format.icon);
      }
      // There is no bespoke dialog or extra Done action to drift from Settings.
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('Done'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('falls back to Modified when Created is unknown', (tester) async {
    await _pumpSheet(
      tester,
      DocumentEntry(
        id: 'fallback-test',
        source: const FileDocumentSource('/does-not-need-to-exist.txt'),
        name: 'Notes.txt',
        format: DocumentFormat.txt,
        sizeBytes: 120,
        modifiedAt: DateTime(2026, 9, 13),
      ),
    );
    expect(find.text('Created'), findsOneWidget);
    expect(find.text('Modified'), findsOneWidget);
    // Both rows show the modification date when creation is unknown
    // (e.g. legacy cache entries).
    expect(find.text('Sep 13, 2026'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  for (final (bytes, expected) in <(int, String)>[
    (0, '0 B'),
    (1023, '1023 B'),
    (1024, '1.0 KB'),
    (1536, '1.5 KB'),
    (10240, '10 KB'),
    (1048576, '1.0 MB'),
    (1572864, '1.5 MB'),
  ]) {
    testWidgets('retains size formatting: $bytes bytes', (tester) async {
      await _pumpSheet(
        tester,
        DocumentEntry(
          id: 'size-test',
          source: const FileDocumentSource('/does-not-need-to-exist.txt'),
          name: 'Notes.txt',
          format: DocumentFormat.txt,
          sizeBytes: bytes,
          modifiedAt: DateTime(2026, 9, 13),
        ),
      );
      expect(find.text(expected), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _pumpSheet(WidgetTester tester, DocumentEntry document) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: SizedBox(width: 400, child: FileInfoSheet(document: document)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
