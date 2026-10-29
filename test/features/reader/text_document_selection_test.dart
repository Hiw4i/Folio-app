import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
      expect(copy, source);
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

  testWidgets('range copy retains heading and emphasis Markdown syntax', (
    tester,
  ) async {
    const source = '# Heading\n\n**Alpha** paragraph.\n\nDo not copy this.';
    await pumpSelection(
      tester,
      source: document(source, markdown: true),
      child: const SingleChildScrollView(
        padding: EdgeInsets.all(40),
        child: MarkdownBody(data: source, selectable: false),
      ),
    );
    final first = tester.getRect(find.text('Heading'));
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.text('Alpha paragraph.'),
        matching: find.byType(RichText),
      ),
    );
    final end = paragraph.localToGlobal(
      paragraph
              .getBoxesForSelection(
                const TextSelection(baseOffset: 0, extentOffset: 5),
              )
              .last
              .toRect()
              .centerRight -
          const Offset(.1, 0),
    );
    final gesture = await tester.startGesture(
      first.centerLeft + const Offset(.1, 0),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(end);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(await copyCurrentSelection(tester), '# Heading\n\n**Alpha**');
  });

  testWidgets('backward Markdown range copy preserves both source endpoints', (
    tester,
  ) async {
    const source = '# Heading\n\n**Alpha** paragraph.\n\nDo not copy this.';
    await pumpSelection(
      tester,
      source: document(source, markdown: true),
      child: const SingleChildScrollView(
        padding: EdgeInsets.all(40),
        child: MarkdownBody(data: source, selectable: false),
      ),
    );
    final heading = tester.getRect(find.text('Heading'));
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.text('Alpha paragraph.'),
        matching: find.byType(RichText),
      ),
    );
    final start = paragraph.localToGlobal(
      paragraph
              .getBoxesForSelection(
                const TextSelection(baseOffset: 0, extentOffset: 5),
              )
              .last
              .toRect()
              .centerRight -
          const Offset(.1, 0),
    );
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(heading.centerLeft + const Offset(.1, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(await copyCurrentSelection(tester), '# Heading\n\n**Alpha**');
  });

  testWidgets(
    'shrinking a bold word does not leave an unmatched Markdown marker',
    (tester) async {
      const source = '**Alpha** paragraph.';
      await pumpSelection(
        tester,
        source: document(source, markdown: true),
        child: const SingleChildScrollView(
          padding: EdgeInsets.all(40),
          child: MarkdownBody(data: source, selectable: false),
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.text('Alpha paragraph.'),
          matching: find.byType(RichText),
        ),
      );
      final word = paragraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 5),
          )
          .first
          .toRect();
      final interior = paragraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 2),
          )
          .first
          .toRect();
      // Long press moves by whole words, so it can only keep the full styled
      // node. A character-level mouse drag genuinely shrinks the range.
      final gesture = await tester.startGesture(
        paragraph.localToGlobal(word.centerLeft + const Offset(.1, 0)),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(
        paragraph.localToGlobal(interior.centerRight - const Offset(.1, 0)),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(await copyCurrentSelection(tester), 'Al');
    },
  );

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
    // Logical anchors can leave the viewport; toolbar layout clamps its
    // animated position without switching the selection to the opposite edge.
    expect(menu.anchors.primaryAnchor.dy.isFinite, isTrue);
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

  test('Markdown full Copy unwraps == highlighted text', () {
    final value = markdownSelectionText(
      'Plain ==marked== and ==spaced phrase==.',
    );
    expect(value, 'Plain marked and spaced phrase.');
  });

  List<Rect> highlightRects(WidgetTester tester) {
    final highlight = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.foregroundPainter is FolioSelectionHighlightPainter,
      ),
    );
    return (highlight.foregroundPainter! as FolioSelectionHighlightPainter)
        .visibleRects();
  }

  Future<List<Rect>> dragAcross(
    WidgetTester tester, {
    required String from,
    required String to,
  }) async {
    final start = tester.getRect(find.text(from).first);
    final end = tester.getRect(find.text(to).first);
    final gesture = await tester.startGesture(
      start.centerLeft + const Offset(2, 0),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(end.center);
    await gesture.up();
    await tester.pumpAndSettle();
    return highlightRects(tester);
  }

  testWidgets('a selected heading shares one silhouette with its body', (
    tester,
  ) async {
    const source =
        '# Chapter title\n\nFirst body paragraph with words in it.\n\n'
        'Second body paragraph with more words.';
    await pumpSelection(
      tester,
      source: document(source, markdown: true),
      child: const SingleChildScrollView(
        padding: EdgeInsets.all(40),
        child: MarkdownBody(data: source, selectable: false),
      ),
    );
    final rects = await dragAcross(
      tester,
      from: 'Chapter title',
      to: 'First body paragraph with words in it.',
    );
    expect(rects.length, greaterThanOrEqualTo(2));
    expect(folioSelectionPath(rects).computeMetrics().length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('highlight height ignores which letters the line contains', (
    tester,
  ) async {
    // Descenders used to make a selected line taller, so the same paragraph
    // merged or split depending on the words the drag happened to cover.
    const source = 'The sun goes up\n\nA gypsy jumping down\n\nThe end of it';
    await pumpSelection(
      tester,
      source: document(source, markdown: true),
      child: const SingleChildScrollView(
        padding: EdgeInsets.all(40),
        child: MarkdownBody(data: source, selectable: false),
      ),
    );
    final rects = await dragAcross(
      tester,
      from: 'The sun goes up',
      to: 'A gypsy jumping down',
    );
    expect(rects.length, greaterThanOrEqualTo(2));
    for (final rect in rects) {
      expect(rect.height, closeTo(rects.first.height, 0.5));
    }
    expect(folioSelectionPath(rects).computeMetrics().length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wrapped heading keeps its short last line while scrolling', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await (FontLoader(
        'Inter',
      )..addFont(rootBundle.load('assets/fonts/Inter.ttf'))).load();
    });
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    const heading = 'A wide heading with many words\ncode';
    const body = 'First paragraph with enough words to select.';
    await pumpSelection(
      tester,
      source: document('$heading\n\n$body'),
      child: SingleChildScrollView(
        controller: scroll,
        padding: const EdgeInsets.all(40),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              heading,
              style: TextStyle(fontFamily: 'Inter', fontSize: 30, height: 1.18),
            ),
            SizedBox(height: 13),
            Text(body, style: TextStyle(fontSize: 17, height: 1.58)),
            SizedBox(height: 1400),
          ],
        ),
      ),
    );
    final initial = await dragAcross(tester, from: heading, to: body);
    final headingParagraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: find.text(heading), matching: find.byType(RichText)),
    );
    final lastLine = headingParagraph
        .getBoxesForSelection(
          const TextSelection(
            baseOffset: heading.length - 4,
            extentOffset: heading.length,
          ),
          boxHeightStyle: ui.BoxHeightStyle.strut,
        )
        .last
        .toRect();
    final expectedWidth = lastLine.width;
    for (final offset in <double>[0, .25, 13, 25, 38, 80, 120]) {
      List<Rect>? painted;
      // Inspect the paint frame before Scrollable's deferred geometry refresh.
      tester.binding.addPostFrameCallback((_) {
        painted = highlightRects(tester);
      });
      scroll.jumpTo(offset);
      tester.binding.scheduleFrame();
      await tester.pump();
      final lineCenter = headingParagraph.localToGlobal(lastLine.center).dy;
      final selected = painted!.where(
        (rect) => (rect.center.dy - lineCenter).abs() < 1,
      );
      expect(selected, hasLength(1), reason: 'scroll offset $offset');
      expect(selected.single.width, closeTo(expectedWidth, .01));
      await tester.pumpAndSettle();
    }
    expect(initial, isNotEmpty);
  });
}
