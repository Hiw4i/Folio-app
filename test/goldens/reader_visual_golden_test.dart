import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/app/folio_app.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/library/data/in_memory_library_repository.dart';
import 'package:folio/features/reader/data/document_content_source.dart';
import 'package:folio/shared/glass/widgets/liquid_search_control.dart';

import '../support/memory_settings_store.dart';

void main() {
  setUpAll(() async {
    final inter = FontLoader('Inter')
      ..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await inter.load();
  });

  testWidgets('TXT reader visual state', (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const path = '/golden/reader.txt';
    final document = DocumentEntry(
      id: path,
      source: const FileDocumentSource(path),
      name: 'Design principles.txt',
      format: DocumentFormat.txt,
      sizeBytes: 430,
      modifiedAt: DateTime.utc(2026, 9, 13),
    );
    await tester.pumpWidget(
      FolioApp(
        settingsStore: MemorySettingsStore(),
        libraryRepository: InMemoryLibraryRepository(
          documents: <DocumentEntry>[document],
        ),
        documentContentSource: MemoryDocumentContentSource(<String, Uint8List>{
          path: Uint8List.fromList(
            utf8.encode(
              'A quiet document\n\n'
              'The document is the primary object. Controls stay close to '
              'the edges and move away while reading.\n\n'
              'Typography should feel calm, deliberate, and effortless. '
              'Every interaction responds with soft physical movement.',
            ),
          ),
        }),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design principles.txt'));
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

    await expectLater(
      find.byKey(const ValueKey<String>('reader_surface')),
      matchesGoldenFile('reader_txt.png'),
    );

    await tester.tap(find.byKey(const ValueKey<String>('reader_menu_button')));
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await expectLater(
      find.byKey(const ValueKey<String>('reader_surface')),
      matchesGoldenFile('reader_menu_morphing.png'),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const ValueKey<String>('reader_surface')),
      matchesGoldenFile('reader_menu_open.png'),
    );
    await tester.tapAt(const Offset(20, 450));
    await tester.pumpAndSettle();

    tester
        .state<LiquidSearchControlState>(find.byType(LiquidSearchControl))
        .open();
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const ValueKey<String>('reader_surface')),
      matchesGoldenFile('reader_search_empty.png'),
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('search_editable')),
      'document',
    );
    await tester.pump(const Duration(milliseconds: 200));
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      if (find.text('1 of 2').evaluate().isNotEmpty) {
        break;
      }
    }
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const ValueKey<String>('reader_surface')),
      matchesGoldenFile('reader_search.png'),
    );
  });
}
