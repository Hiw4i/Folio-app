import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_tutorial_store.dart';

import 'package:folio/app/folio_app.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/library/data/in_memory_library_repository.dart';
import 'package:folio/features/library/data/library_repository.dart';
import 'package:folio/features/reader/data/document_content_source.dart';
import 'package:folio/shared/glass/widgets/liquid_glass_button.dart';
import 'package:folio/shared/settings/folio_settings.dart';

import '../../support/memory_settings_store.dart';

void main() {
  testWidgets('the permission card centers its action button', (tester) async {
    const path = '/documents/notes.txt';
    final document = DocumentEntry(
      id: path,
      source: const FileDocumentSource(path),
      name: 'Notes.txt',
      format: DocumentFormat.txt,
      sizeBytes: 10,
      modifiedAt: DateTime.utc(2026, 11, 2),
    );
    await tester.pumpWidget(
      FolioApp(
        tutorialStore: MemoryTutorialStore.allSeen(),
        settingsStore: MemorySettingsStore(const FolioSettings()),
        libraryRepository: InMemoryLibraryRepository(
          access: LibraryAccess.denied,
          documents: <DocumentEntry>[document],
        ),
        documentContentSource: MemoryDocumentContentSource(<String, Uint8List>{
          path: Uint8List.fromList(utf8.encode('text')),
        }),
      ),
    );
    await tester.pumpAndSettle();

    final button = find.byType(LiquidGlassButton);
    expect(button, findsOneWidget);
    final card = find.byWidgetPredicate(
      (widget) =>
          widget is ConstrainedBox && widget.constraints.maxWidth == 600,
    );
    expect(card, findsOneWidget);

    // The action sits on the card's horizontal center line.
    expect(
      (tester.getCenter(button).dx - tester.getCenter(card).dx).abs(),
      lessThan(1.0),
    );
  });
}
