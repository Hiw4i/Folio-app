import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/reader/text/data/text_document.dart';
import 'package:folio/features/reader/text/widgets/text_selection_source.dart';

void main() {
  Future<void> pumpChunks(
    WidgetTester tester,
    TextSelectionSourceRegistry registry,
    List<TextDocumentChunk> chunks,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            child: TextSelectionSourceScope(
              registry: registry,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(30),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final chunk in chunks)
                      TextSelectionSourceChunk(
                        chunk: chunk,
                        isMarkdown: true,
                        child: MarkdownBody(
                          data:
                              '${chunk.renderPrefix}${chunk.text}${chunk.renderSuffix}',
                          selectable: false,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('select all maps original source across repeated chunks', (
    tester,
  ) async {
    final registry = TextSelectionSourceRegistry();
    await pumpChunks(tester, registry, const [
      TextDocumentChunk(startOffset: 0, text: '**same**\n\n'),
      TextDocumentChunk(startOffset: 10, text: '# same\n'),
    ]);
    tester
        .state<SelectableRegionState>(find.byType(SelectableRegion))
        .selectAll(SelectionChangedCause.toolbar);
    await tester.pumpAndSettle();
    final range = registry.selectedSourceRange!;
    expect(range.start, 0);
    expect(range.end, 17);
    expect(registry.selectables, isNotEmpty);
  });

  testWidgets('dragging second repeated label copies its own syntax', (
    tester,
  ) async {
    final registry = TextSelectionSourceRegistry();
    await pumpChunks(tester, registry, const [
      TextDocumentChunk(startOffset: 0, text: '**same**\n\n'),
      TextDocumentChunk(startOffset: 10, text: '# same\n'),
    ]);
    final rect = tester.getRect(find.text('same').last);
    final gesture = await tester.startGesture(
      rect.centerLeft + const Offset(1, 0),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(rect.centerRight - const Offset(1, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    final range = registry.selectedSourceRange!;
    expect(range.start, 10);
    expect(range.end, 17);
  });

  testWidgets('WidgetSpan search hits retain paragraph selection offsets', (
    tester,
  ) async {
    final registry = TextSelectionSourceRegistry();
    const source = 'Before **bold hit** after';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            child: TextSelectionSourceScope(
              registry: registry,
              child: const TextSelectionSourceChunk(
                chunk: TextDocumentChunk(startOffset: 40, text: source),
                isMarkdown: true,
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: 'Before '),
                      WidgetSpan(child: Text('bold')),
                      TextSpan(text: ' hit after'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester
        .state<SelectableRegionState>(find.byType(SelectableRegion))
        .selectAll(SelectionChangedCause.toolbar);
    await tester.pumpAndSettle();
    final range = registry.selectedSourceRange!;
    expect(range.start, 40);
    expect(range.end, 40 + source.length);
    expect(registry.selectables.length, 3);
  });

  testWidgets('carried fence markers never leak into real chunk offsets', (
    tester,
  ) async {
    final registry = TextSelectionSourceRegistry();
    await pumpChunks(tester, registry, const [
      TextDocumentChunk(
        startOffset: 100,
        text: 'second line\n',
        renderPrefix: '```dart\n',
        renderSuffix: '\n```\n',
      ),
    ]);
    tester
        .state<SelectableRegionState>(find.byType(SelectableRegion))
        .selectAll(SelectionChangedCause.toolbar);
    await tester.pumpAndSettle();
    final range = registry.selectedSourceRange!;
    expect(range.start, 100);
    expect(range.end, 112);
  });
}
