import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_tutorial_store.dart';

import 'package:folio/app/folio_app.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/library/data/in_memory_library_repository.dart';
import 'package:folio/features/reader/data/document_content_source.dart';
import 'package:folio/features/reader/logic/reader_preloader.dart';
import 'package:folio/features/reader/widgets/reader_screen.dart';

import '../../support/memory_settings_store.dart';

void main() {
  testWidgets(
    'moving an open row to Recents does not lock subsequent navigation',
    (tester) async {
      final documents = <DocumentEntry>[
        for (final name in <String>['Alpha.txt', 'Beta.txt'])
          DocumentEntry(
            id: name,
            source: FileDocumentSource('/$name'),
            name: name,
            format: DocumentFormat.txt,
            sizeBytes: 30,
            modifiedAt: DateTime.utc(2026, 9, 18),
          ),
      ];
      final source = MemoryDocumentContentSource(<String, Uint8List>{
        for (final document in documents)
          document.source.value: Uint8List.fromList(
            utf8.encode('Readable content.'),
          ),
      });
      addTearDown(ReaderPreloader.resetForTest);
      await tester.pumpWidget(
        FolioApp(
          tutorialStore: MemoryTutorialStore.allSeen(),
          libraryRepository: InMemoryLibraryRepository(documents: documents),
          documentContentSource: source,
          settingsStore: MemorySettingsStore(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alpha.txt'));
      await tester.pumpAndSettle();
      // Recents is updated after the 340 ms container transform.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ReaderScreen>(find.byType(ReaderScreen)).document.id,
        'Alpha.txt',
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsNothing);
      await tester.tap(find.text('Beta.txt'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ReaderScreen>(find.byType(ReaderScreen)).document.id,
        'Beta.txt',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}
