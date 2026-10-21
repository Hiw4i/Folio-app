import 'package:animations/animations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/app/folio_app.dart';
import 'package:folio/features/library/data/in_memory_library_repository.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/shared/widgets/scroll_edge_fade.dart';

void main() {
  testWidgets('catalog filters and liquid search update visible documents', (
    tester,
  ) async {
    await tester.pumpWidget(
      FolioApp(libraryRepository: InMemoryLibraryRepository.demo()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Folio'), findsOneWidget);
    expect(find.byType(ScrollEdgeFade), findsOneWidget);
    expect(find.text('RECENT'), findsOneWidget);
    expect(find.text('Product principles.pdf'), findsOneWidget);

    await tester.tap(find.text('PPTX'));
    await tester.pumpAndSettle();
    expect(find.text('Roadmap.pptx'), findsOneWidget);
    expect(find.text('Annual report.pdf'), findsNothing);

    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey<String>('search_button_hit'))),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.enterText(
      find.byKey(const ValueKey<String>('search_editable')),
      'launch',
    );
    await tester.pump();

    expect(find.text('Launch review.pptx'), findsOneWidget);
    expect(find.text('Roadmap.pptx'), findsNothing);
    expect(find.text('RESULTS'), findsOneWidget);
  });

  testWidgets('unavailable Recent shows recovery and Back dismisses it', (
    tester,
  ) async {
    final source = const UriDocumentSource('content://test/missing');
    final missing = DocumentEntry(
      id: stableDocumentId(source),
      source: source,
      name: 'Missing.pdf',
      format: DocumentFormat.pdf,
      sizeBytes: 42,
      modifiedAt: DateTime.utc(2026, 9, 13),
      lastOpenedAt: DateTime.utc(2026, 9, 13),
      isAvailable: false,
    );
    await tester.pumpWidget(
      FolioApp(
        libraryRepository: InMemoryLibraryRepository(
          documents: <DocumentEntry>[missing],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Missing.pdf'));
    await tester.pump();
    expect(find.text('File access expired'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('File access expired'), findsNothing);
  });

  testWidgets('document rows open the reader with a container transform', (
    tester,
  ) async {
    await tester.pumpWidget(
      FolioApp(libraryRepository: InMemoryLibraryRepository.demo()),
    );
    await tester.pumpAndSettle();

    expect(find.byType(OpenContainer<void>), findsWidgets);

    await tester.tap(find.text('Product principles.pdf'));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('reader_surface')),
      findsOneWidget,
    );

    // Flush the deferred Recents update (360ms after the container morph).
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('dragging the selected filter lens changes the format', (
    tester,
  ) async {
    await tester.pumpWidget(
      FolioApp(libraryRepository: InMemoryLibraryRepository.demo()),
    );
    await tester.pumpAndSettle();
    final filter = find.byKey(const ValueKey<String>('format_filters'));
    final rect = tester.getRect(filter);
    final itemWidth = rect.width / 5;

    await tester.timedDragFrom(
      Offset(rect.left + itemWidth / 2, rect.center.dy),
      Offset(itemWidth * 3, 0),
      const Duration(milliseconds: 420),
    );
    await tester.pumpAndSettle();

    expect(find.text('Roadmap.pptx'), findsOneWidget);
    expect(find.text('Annual report.pdf'), findsNothing);
  });
}
