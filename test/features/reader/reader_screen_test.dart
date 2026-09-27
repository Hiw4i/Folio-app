import 'dart:convert';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:folio/app/folio_app.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/library/data/in_memory_library_repository.dart';
import 'package:folio/features/reader/data/document_content_source.dart';
import 'package:folio/features/reader/widgets/file_info_sheet.dart';
import 'package:folio/shared/glass/widgets/liquid_glass_control.dart';
import 'package:folio/shared/glass/widgets/liquid_search_control.dart';
import 'package:folio/shared/theme/folio_theme.dart';
import 'package:folio/shared/widgets/folio_sheet_content.dart';

void main() {
  const path = '/documents/notes.txt';
  final document = DocumentEntry(
    id: path,
    source: const FileDocumentSource(path),
    name: 'Notes.txt',
    format: DocumentFormat.txt,
    sizeBytes: 120,
    modifiedAt: DateTime.utc(2026, 9, 13),
  );

  Future<void> openReader(WidgetTester tester) async {
    await tester.pumpWidget(
      FolioApp(
        libraryRepository: InMemoryLibraryRepository(
          documents: <DocumentEntry>[document],
        ),
        documentContentSource: MemoryDocumentContentSource(<String, Uint8List>{
          path: Uint8List.fromList(
            utf8.encode(
              'Quiet text.\n\nSearch target and another target.\n\n'
              '${List<String>.filled(90, 'A calm line for scrolling.\n\n').join()}',
            ),
          ),
        }),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notes.txt'));
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
  }

  testWidgets('catalog opens TXT in the reader and searches its text', (
    tester,
  ) async {
    await openReader(tester);

    expect(
      find.byKey(const ValueKey<String>('reader_surface')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('reader_content')),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate((widget) => widget is SelectableRegion),
      findsWidgets,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            (widget.textSpan?.toPlainText() ?? '').contains('Quiet text.'),
      ),
      findsOneWidget,
    );

    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey<String>('search_button_hit'))),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('search_editable')),
      'target',
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

    expect(find.text('1 of 2'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('reader_search_navigator_glass')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('reader_next_hit')));
    await tester.pumpAndSettle();
    expect(find.text('2 of 2'), findsOneWidget);
    _expectActivePlainTextHitInReadingArea(tester);
  });

  testWidgets('plain text selection exposes the Android copy action', (
    tester,
  ) async {
    await openReader(tester);

    final selectionArea = find
        .byWidgetPredicate((widget) => widget is SelectableRegion)
        .first;
    final selectionState = tester.state<SelectableRegionState>(selectionArea);
    selectionState.selectAll();
    await tester.pump();
    expect(
      selectionState.contextMenuButtonItems.any(
        (item) => item.type == ContextMenuButtonType.copy,
      ),
      isTrue,
    );
    selectionState.clearSelection();
  });

  testWidgets('search arrows reveal exact matches across lazy text chunks', (
    tester,
  ) async {
    const longPath = '/documents/long-notes.txt';
    final longDocument = DocumentEntry(
      id: longPath,
      source: const FileDocumentSource(longPath),
      name: 'Long notes.txt',
      format: DocumentFormat.txt,
      sizeBytes: 24000,
      modifiedAt: DateTime.utc(2026, 9, 13),
    );
    String section(int number) {
      final before = List<String>.filled(
        100,
        'Calm lead-in line for section $number.\n\n',
      ).join();
      final after = List<String>.filled(
        110,
        'Quiet trailing line for section $number.\n\n',
      ).join();
      return '$before needle-$number target $after';
    }

    await tester.pumpWidget(
      FolioApp(
        libraryRepository: InMemoryLibraryRepository(
          documents: <DocumentEntry>[longDocument],
        ),
        documentContentSource: MemoryDocumentContentSource(<String, Uint8List>{
          longPath: Uint8List.fromList(
            utf8.encode('${section(1)}${section(2)}${section(3)}'),
          ),
        }),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Long notes.txt'));
    await _waitForReaderContent(tester);

    tester
        .state<LiquidSearchControlState>(find.byType(LiquidSearchControl))
        .open();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.enterText(
      find.byKey(const ValueKey<String>('search_editable')),
      'target',
    );
    await tester.pump(const Duration(milliseconds: 200));
    await _waitForText(tester, '1 of 3');
    _expectActivePlainTextHitInReadingArea(tester);

    final list = tester.widget<ListView>(
      find.byKey(const ValueKey<String>('reader_content')),
    );
    final firstOffset = list.controller!.offset;
    await tester.tap(find.byKey(const ValueKey<String>('reader_next_hit')));
    await tester.pumpAndSettle();
    expect(find.text('2 of 3'), findsOneWidget);
    expect(list.controller!.offset, greaterThan(firstOffset + 200));
    _expectActivePlainTextHitInReadingArea(tester);

    final secondOffset = list.controller!.offset;
    await tester.tap(find.byKey(const ValueKey<String>('reader_next_hit')));
    await tester.pumpAndSettle();
    expect(find.text('3 of 3'), findsOneWidget);
    expect(list.controller!.offset, greaterThan(secondOffset + 200));
    _expectActivePlainTextHitInReadingArea(tester);

    await tester.tap(find.byKey(const ValueKey<String>('reader_previous_hit')));
    await tester.pumpAndSettle();
    expect(find.text('2 of 3'), findsOneWidget);
    _expectActivePlainTextHitInReadingArea(tester);
  });

  testWidgets('Back closes keyboard, search, then reader route', (
    tester,
  ) async {
    await openReader(tester);
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey<String>('search_button_hit'))),
    );
    await tester.pumpAndSettle();
    final searchState = tester.state<LiquidSearchControlState>(
      find.byType(LiquidSearchControl),
    );
    expect(searchState.isExpanded, isTrue);
    // Both the bottom-left indicator and the right-edge scrub pill show
    // the live progress: scope to the bottom-left one.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('reader_progress_glass')),
        matching: find.text('0%'),
      ),
      findsOneWidget,
    );
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Search field');

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('reader_surface')),
      findsOneWidget,
    );
    expect(searchState.isExpanded, isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('reader_surface')),
      findsOneWidget,
    );
    expect(searchState.isExpanded, isFalse);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Folio'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('reader_surface')), findsNothing);
  });

  testWidgets('tapping an expanded search field restores input focus', (
    tester,
  ) async {
    await openReader(tester);
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey<String>('search_button_hit'))),
    );
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      isNot('Search field'),
    );

    await tester.tap(find.byKey(const ValueKey<String>('search_editable')));
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Search field');
    expect(
      tester
          .state<LiquidSearchControlState>(find.byType(LiquidSearchControl))
          .isExpanded,
      isTrue,
    );
  });

  testWidgets('reader menu shows file information', (tester) async {
    await openReader(tester);

    await tester.tap(find.byKey(const ValueKey<String>('reader_menu_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('File info'));
    await tester.pumpAndSettle();

    expect(find.byType(FileInfoSheet), findsOneWidget);
    expect(find.byType(FolioSheetContent), findsOneWidget);
    expect(find.text('FILE INFO'), findsOneWidget);
    expect(find.text('TXT'), findsOneWidget);
    expect(find.text('120 B'), findsOneWidget);
  });

  testWidgets('File info closes before the reader and can be reopened', (
    tester,
  ) async {
    await openReader(tester);
    for (var attempt = 0; attempt < 2; attempt++) {
      await _openFileInfo(tester);
      await tester.pumpAndSettle();
      expect(find.byType(FileInfoSheet), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(FileInfoSheet), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('reader_surface')),
        findsOneWidget,
      );
      expect(find.text('Remove from Recents'), findsNothing);
    }
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('reader_surface')), findsNothing);
    expect(find.text('Folio'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rapid File info actions and Back cannot stack or pop the reader',
    (tester) async {
      await openReader(tester);
      await tester.tap(
        find.byKey(const ValueKey<String>('reader_menu_button')),
      );
      await tester.pumpAndSettle();
      final action = tester
          .widget<GestureDetector>(
            find
                .ancestor(
                  of: find.text('File info'),
                  matching: find.byType(GestureDetector),
                )
                .first,
          )
          .onTap!;
      action();
      action(); // Before the first opening frame.
      await tester.pumpAndSettle();
      expect(find.byType(FileInfoSheet), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      action(); // The closing animation must still hold the modal guard.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(FileInfoSheet), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('folio_sheet_backdrop')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('reader_surface')),
        findsOneWidget,
      );

      await _openFileInfo(tester);
      await tester.pumpAndSettle();
      expect(find.byType(FileInfoSheet), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('File info releases search focus without losing the query', (
    tester,
  ) async {
    await openReader(tester);
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey<String>('search_button_hit'))),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('search_editable')),
      'quiet',
    );
    await tester.pump(const Duration(milliseconds: 200));
    await _waitForText(tester, '1 of 1');
    final search = tester.state<LiquidSearchControlState>(
      find.byType(LiquidSearchControl),
    );
    await _openFileInfo(tester);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      isNot('Search field'),
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      tester.state<LiquidSearchControlState>(find.byType(LiquidSearchControl)),
      same(search),
    );
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const ValueKey<String>('search_editable')),
              matching: find.byType(EditableText),
            ),
          )
          .controller
          .text,
      'quiet',
    );
    expect(find.text('1 of 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing the reader during File info opening is safe', (
    tester,
  ) async {
    await openReader(tester);
    await _openFileInfo(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reader menu morph closes after an outside tap', (tester) async {
    await openReader(tester);

    await tester.tap(find.byKey(const ValueKey<String>('reader_menu_button')));
    await tester.pumpAndSettle();
    expect(find.text('Remove from Recents'), findsOneWidget);

    await tester.tapAt(const Offset(24, 430));
    await tester.pumpAndSettle();
    expect(find.text('Remove from Recents'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('reader_menu_button')),
      findsOneWidget,
    );
  });

  testWidgets('title and progress use deformable liquid surfaces', (
    tester,
  ) async {
    await openReader(tester);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('reader_title_glass')),
        matching: find.byType(LiquidGlassControl),
      ),
      findsOneWidget,
    );
    final titleSize = tester.getSize(
      find.byKey(const ValueKey<String>('reader_title_glass')),
    );
    expect(titleSize.height, 42);
    expect(titleSize.width, lessThan(180));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('reader_progress_glass')),
        matching: find.byType(LiquidGlassControl),
      ),
      findsOneWidget,
    );
  });

  testWidgets('chrome hides on downward scroll and returns on content tap', (
    tester,
  ) async {
    await openReader(tester);
    final topChrome = find.byKey(const ValueKey<String>('reader_top_chrome'));
    final topGlass = find.descendant(
      of: topChrome,
      matching: find.byType(LiquidGlassControl),
    );
    expect(topGlass, findsWidgets);

    // Tiny adjustments while reading do not start a close animation.
    await tester.drag(
      find.byKey(const ValueKey<String>('reader_content')),
      const Offset(0, -10),
    );
    await tester.pumpAndSettle();
    expect(topGlass, findsWidgets);

    await tester.drag(
      find.byKey(const ValueKey<String>('reader_content')),
      const Offset(0, -320),
    );
    // First pump delivers the scroll notification and starts reverse;
    // second pump catches the shared slide mid-flight.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final midHideTransform = find.descendant(
      of: topChrome,
      matching: find.byType(Transform),
    );
    expect(midHideTransform, findsWidgets);

    await tester.pumpAndSettle();
    // Hidden chrome is unmounted: no backdrop blur cost while reading.
    expect(topChrome, findsOneWidget);
    expect(
      find.descendant(of: topChrome, matching: find.byType(LiquidGlassControl)),
      findsNothing,
    );

    await tester.tapAt(const Offset(200, 430));
    // Mid-show: slide runs in the opposite direction as well.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final midShowTransform = find.descendant(
      of: topChrome,
      matching: find.byType(Transform),
    );
    expect(midShowTransform, findsWidgets);

    await tester.pumpAndSettle();
    expect(
      find.descendant(of: topChrome, matching: find.byType(LiquidGlassControl)),
      findsWidgets,
    );
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .descendant(of: topChrome, matching: find.byType(IgnorePointer))
                .first,
          )
          .ignoring,
      isFalse,
    );
  });

  testWidgets('Markdown renders locally and blocks remote image loading', (
    tester,
  ) async {
    const markdownPath = '/documents/notes.md';
    final markdownDocument = DocumentEntry(
      id: markdownPath,
      source: const FileDocumentSource(markdownPath),
      name: 'Notes.md',
      format: DocumentFormat.markdown,
      sizeBytes: 180,
      modifiedAt: DateTime.utc(2026, 9, 13),
    );
    await tester.pumpWidget(
      FolioApp(
        libraryRepository: InMemoryLibraryRepository(
          documents: <DocumentEntry>[markdownDocument],
        ),
        documentContentSource: MemoryDocumentContentSource(<String, Uint8List>{
          markdownPath: Uint8List.fromList(
            utf8.encode(
              '# Local notes\n\nA **quiet** reader.\n\n'
              '![Remote illustration](https://example.com/image.png)',
            ),
          ),
        }),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notes.md'));
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

    expect(find.text('Local notes'), findsOneWidget);
    expect(find.text('Remote illustration'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(
      tester.widget<MarkdownBody>(find.byType(MarkdownBody)).selectable,
      isFalse, // Selection is owned by the one surrounding document area.
    );

    tester
        .state<LiquidSearchControlState>(find.byType(LiquidSearchControl))
        .open();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.enterText(
      find.byKey(const ValueKey<String>('search_editable')),
      'quiet',
    );
    await tester.pump(const Duration(milliseconds: 200));
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      if (find.text('1 of 1').evaluate().isNotEmpty) {
        break;
      }
    }
    await tester.pumpAndSettle();
    expect(find.text('1 of 1'), findsOneWidget);
  });
}

Future<void> _openFileInfo(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('reader_menu_button')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('File info'));
}

Future<void> _waitForReaderContent(WidgetTester tester) async {
  for (var attempt = 0; attempt < 30; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
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
}

Future<void> _waitForText(WidgetTester tester, String value) async {
  for (var attempt = 0; attempt < 30; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
    if (find.text(value).evaluate().isNotEmpty) {
      break;
    }
  }
  await tester.pumpAndSettle();
}

void _expectActivePlainTextHitInReadingArea(WidgetTester tester) {
  final activeText = find.descendant(
    of: find.byKey(const ValueKey<String>('reader_content')),
    matching: find.byWidgetPredicate(
      (widget) => widget is Text && _activeSelection(widget.textSpan) != null,
    ),
  );
  expect(activeText, findsOneWidget);
  final widget = tester.widget<Text>(activeText);
  final selection = _activeSelection(widget.textSpan)!;
  final richText = find.descendant(
    of: activeText,
    matching: find.byType(RichText),
  );
  expect(richText, findsOneWidget);
  final paragraph = tester.renderObject<RenderParagraph>(richText);
  final boxes = paragraph.getBoxesForSelection(selection);
  expect(boxes, isNotEmpty);
  final globalCenter = paragraph.localToGlobal(boxes.first.toRect().center);
  expect(globalCenter.dy, greaterThan(80));
  expect(globalCenter.dy, lessThan(520));
}

TextSelection? _activeSelection(InlineSpan? root) {
  var offset = 0;
  TextSelection? result;

  void visit(InlineSpan span) {
    if (span case TextSpan(:final text, :final children, :final style)) {
      final start = offset;
      offset += text?.length ?? 0;
      if (style?.backgroundColor == appColors.activeSearchMatch &&
          offset > start) {
        result = TextSelection(baseOffset: start, extentOffset: offset);
      }
      if (children != null) {
        for (final child in children) {
          visit(child);
        }
      }
    }
  }

  if (root != null) {
    visit(root);
  }
  return result;
}
