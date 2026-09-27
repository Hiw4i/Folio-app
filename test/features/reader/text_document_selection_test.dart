import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:folio/features/reader/text/data/text_document.dart';
import 'package:folio/features/reader/text/logic/markdown_selection_text.dart';
import 'package:folio/features/reader/text/widgets/text_document_selection.dart';
import 'package:folio/shared/theme/folio_theme.dart';
import 'package:folio/shared/selection/folio_selection_toolbar.dart';
import 'package:folio/shared/selection/selection_visuals.dart';

final _regionFinder = find.byWidgetPredicate(
  (widget) => widget is SelectableRegion,
);

void main() {
  TextDocument document(String source, {bool markdown = false}) => TextDocument(
    text: source,
    chunks: <TextDocumentChunk>[
      TextDocumentChunk(startOffset: 0, text: source),
    ],
    encoding: TextDocumentEncoding.utf8,
    isMarkdown: markdown,
  );

  Future<void> pumpSelection(
    WidgetTester tester, {
    required TextDocument source,
    required Widget child,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          textSelectionTheme: TextSelectionThemeData(
            selectionColor: appColors.selection,
            selectionHandleColor: appColors.selectionHandle,
          ),
        ),
        home: Scaffold(
          body: TextDocumentSelection(document: source, child: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<String> copyCurrentSelection(
    WidgetTester tester, {
    bool selectAll = false,
  }) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        if (call.method == 'Clipboard.hasStrings') {
          return <String, bool>{'value': false};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final region = tester.state<SelectableRegionState>(_regionFinder);
    if (selectAll) {
      region.selectAll(SelectionChangedCause.toolbar);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('folio_toolbar_copy')),
      );
    } else {
      final config = tester.widget<SelectableRegion>(_regionFinder);
      final menu = config.contextMenuBuilder!(
        tester.element(_regionFinder),
        region,
      ) as FolioSelectionToolbar;
      menu.buttonItems
          .firstWhere((item) => item.type == ContextMenuButtonType.copy)
          .onPressed!();
    }
    await tester.pumpAndSettle();
    expect(copied, isNotNull);
    return copied!;
  }

  testWidgets('Select all copies off-screen TXT without building every chunk', (
    tester,
  ) async {
    final lines = List<String>.generate(600, (i) => 'Paragraph $i.');
    var built = 0;
    await pumpSelection(
      tester,
      source: document(lines.join('\n\n')),
      child: ListView.builder(
        itemCount: lines.length,
        itemExtent: 100,
        itemBuilder: (context, index) {
          built++;
          return Text(lines[index]);
        },
      ),
    );
    expect(_regionFinder, findsOneWidget);
    expect(built, lessThan(40));
    expect(
      await copyCurrentSelection(tester, selectAll: true),
      lines.join('\n\n'),
    );
    expect(built, lessThan(40));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Markdown paragraphs share selection rather than editable fields',
    (tester) async {
      const source = '# Heading\n\nFirst paragraph.\n\nSecond **paragraph**.';
      await pumpSelection(
        tester,
        source: document(source, markdown: true),
        child: const SingleChildScrollView(
          child: MarkdownBody(data: source, selectable: false),
        ),
      );
      expect(_regionFinder, findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      final copy = await copyCurrentSelection(tester, selectAll: true);
      expect(copy, contains('Heading'));
      expect(copy, contains('First paragraph.'));
      expect(copy, contains('Second paragraph.'));
      expect(copy, isNot(contains('**')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mouse drag selects across two Markdown paragraphs', (
    tester,
  ) async {
    const source = 'Alpha paragraph.\n\nBeta paragraph.\n\nGamma paragraph.';
    await pumpSelection(
      tester,
      source: document(source, markdown: true),
      child: const SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: MarkdownBody(data: source, selectable: false),
        ),
      ),
    );
    final first = tester.getRect(find.text('Alpha paragraph.'));
    final second = tester.getRect(find.text('Beta paragraph.'));
    final gesture = await tester.startGesture(
      first.centerLeft + const Offset(1, 0),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(second.centerRight - const Offset(1, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    final selectable = tester.state<SelectableRegionState>(_regionFinder);
    expect(
      selectable.contextMenuButtonItems.any(
        (item) => item.type == ContextMenuButtonType.copy,
      ),
      isTrue,
    );
    final copied = await copyCurrentSelection(tester);
    expect(copied, contains('Alpha paragraph.'));
    expect(copied, contains('Beta paragraph'));
    expect(copied, isNot(contains('Gamma')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Select all stays complete after scrolling a lazy list', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final lines = List<String>.generate(200, (i) => 'Row $i');
    await pumpSelection(
      tester,
      source: document(lines.join('\n')),
      child: ListView.builder(
        controller: controller,
        itemExtent: 100,
        itemCount: lines.length,
        itemBuilder: (_, i) => Text(lines[i]),
      ),
    );
    final region = tester.state<SelectableRegionState>(_regionFinder);
    region.selectAll(SelectionChangedCause.toolbar);
    await tester.pumpAndSettle();
    controller.jumpTo(4000);
    await tester.pumpAndSettle();
    final highlight = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.foregroundPainter is FolioSelectionHighlightPainter,
      ),
    );
    final visibleRects =
        (highlight.foregroundPainter! as FolioSelectionHighlightPainter)
            .visibleRects();
    expect(visibleRects, isNotEmpty);
    final menu =
        tester.widget<SelectableRegion>(_regionFinder).contextMenuBuilder!(
          tester.element(_regionFinder),
          region,
        ) as FolioSelectionToolbar;
    expect(menu.anchors.primaryAnchor.dy, inInclusiveRange(0, 600));
    // Invoke the existing selection's Copy; deliberately do not selectAll again.
    expect(await copyCurrentSelection(tester), lines.join('\n'));
    expect(tester.takeException(), isNull);
  });

  test('Markdown full Copy preserves visible text, code and Unicode', () {
    final value = markdownSelectionText(
      '# Заголовок\n\n**Привет** &amp; [мир](https://example.test).\n\n'
      '```dart\nfinal x = 1 < 2;\n```\n\n![Описание](image.png)',
    );
    expect(value, contains('Заголовок'));
    expect(value, contains('Привет & мир.'));
    expect(value, contains('final x = 1 < 2;'));
    expect(value, contains('Описание'));
    expect(value, isNot(contains('https://example.test')));
    expect(value, isNot(contains('```')));
  });

  test('Markdown full Copy keeps table cells separate', () {
    final value = markdownSelectionText('| A | B |\n| --- | --- |\n| X | Y |');
    expect(value, contains('A\tB'));
    expect(value, contains('X\tY'));
  });
}
