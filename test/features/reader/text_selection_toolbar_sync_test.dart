import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/reader/text/data/text_document.dart';
import 'package:folio/features/reader/text/widgets/text_document_selection.dart';

final _regionFinder = find.byWidgetPredicate(
  (widget) => widget is SelectableRegion,
);
final _copyFinder = find.byKey(const ValueKey<String>('folio_toolbar_copy'));
final _selectAllFinder = find.byKey(
  const ValueKey<String>('folio_toolbar_select_all'),
);

const _source =
    'Alpha paragraph one.\n\nBeta paragraph two.\n\nGamma paragraph three.';

void main() {
  Future<List<bool>> pumpSelection(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 840);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final changes = <bool>[];
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final document = TextDocument(
      text: _source,
      chunks: const <TextDocumentChunk>[
        TextDocumentChunk(startOffset: 0, text: _source),
      ],
      encoding: TextDocumentEncoding.utf8,
      isMarkdown: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: TextDocumentSelection(
            document: document,
            scrollController: scroll,
            onSelectionChanged: changes.add,
            child: SingleChildScrollView(
              controller: scroll,
              padding: const EdgeInsets.all(40),
              child: const Text(_source, style: TextStyle(fontSize: 20)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return changes;
  }

  RenderParagraph paragraph(WidgetTester tester) =>
      tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.text(_source),
          matching: find.byType(RichText),
        ),
      );

  ContextMenuButtonItem? copyItem(WidgetTester tester) {
    for (final item
        in tester
            .state<SelectableRegionState>(_regionFinder)
            .contextMenuButtonItems) {
      if (item.type == ContextMenuButtonType.copy) return item;
    }
    return null;
  }

  Future<void> selectFirstWord(WidgetTester tester) async {
    final text = paragraph(tester);
    final word = text
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 5),
        )
        .first
        .toRect();
    await tester.longPressAt(text.localToGlobal(word.center));
    await tester.pumpAndSettle();
    expect(copyItem(tester), isNotNull);
    // Start a fresh gesture sequence rather than a double tap.
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> dragHandle(WidgetTester tester) async {
    final handle = find
        .byKey(const ValueKey<String>('reader_selection_handle'))
        .last;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(4, 12));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets(
    'tapping outside a handle menu clears the toolbar with selection',
    (tester) async {
      final changes = await pumpSelection(tester);
      await selectFirstWord(tester);
      await dragHandle(tester);
      expect(_copyFinder, findsOneWidget);

      await tester.tapAt(const Offset(20, 700));
      await tester.pumpAndSettle();

      expect(copyItem(tester), isNull);
      expect(_copyFinder, findsNothing);
      expect(changes, contains(false));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an existing selection keeps one toolbar after rotation', (
    tester,
  ) async {
    await pumpSelection(tester);
    await selectFirstWord(tester);
    expect(_copyFinder, findsOneWidget);

    tester.view.physicalSize = const Size(840, 420);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));

    expect(copyItem(tester), isNotNull);
    expect(_copyFinder, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('select all from a handle menu keeps exactly one toolbar', (
    tester,
  ) async {
    await pumpSelection(tester);
    await selectFirstWord(tester);
    await dragHandle(tester);
    expect(_copyFinder, findsOneWidget);

    await tester.tap(_selectAllFinder);
    await tester.pumpAndSettle();

    expect(_copyFinder, findsOneWidget);
    // Everything is selected now, so the pill no longer offers Select all.
    expect(_selectAllFinder, findsNothing);
    expect(copyItem(tester), isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapsing a selection removes a visible toolbar', (
    tester,
  ) async {
    await pumpSelection(tester);
    await selectFirstWord(tester);
    await dragHandle(tester);
    expect(_copyFinder, findsOneWidget);

    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(const Offset(20, 700));
    await tester.pumpAndSettle();

    expect(_copyFinder, findsNothing);
    expect(copyItem(tester), isNull);
    expect(tester.takeException(), isNull);
  });
}
