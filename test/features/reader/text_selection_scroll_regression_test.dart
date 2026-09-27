
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/reader/data/document_content_source.dart';
import 'package:folio/features/reader/logic/reader_state.dart';
import 'package:folio/features/reader/text/data/text_document.dart';
import 'package:folio/features/reader/text/logic/markdown_selection_text.dart';
import 'package:folio/features/reader/text/logic/text_document_renderer.dart';
import 'package:folio/features/reader/text/widgets/text_document_view.dart';
import 'package:folio/shared/selection/folio_selection_toolbar.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

final _regionFinder = find.byWidgetPredicate(
  (widget) => widget is SelectableRegion,
);
final _viewport = find.byKey(const ValueKey<String>('reader_content'));

void main() {
  for (final markdown in <bool>[false, true]) {
    final format = markdown ? 'MD' : 'TXT';
    for (final platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      final label = '$format / ${platform.name}';

      testWidgets('$label keeps a word and native Copy during a touch scroll', (
        tester,
      ) async {
        final fixture = await _pumpReader(tester, markdown, platform);
        await _selectFirstWord(tester);
        fixture.selectionChanges.clear();
        final region = tester.state<SelectableRegionState>(_regionFinder);
        final start = region.selectionEndpoints.first.point;

        await _swipe(tester, const Offset(0, -72));

        expect(fixture.scroll.offset, greaterThan(0));
        expect(fixture.selectionChanges, isNot(contains(false)));
        expect(_canCopy(tester), isTrue);
        // Check the REGION's endpoint owners, not just leaf highlight paint.
        // Ignoring ClearSelection only in a child delegate breaks this state.
        expect(region.selectionEndpoints, hasLength(2));
        expect(region.selectionEndpoints.first.point.dy, lessThan(start.dy));
        expect(await fixture.copy(tester), 'Alpha');
        expect(tester.takeException(), isNull);
      });

      testWidgets('$label clears by a tap, not by the preceding swipe', (
        tester,
      ) async {
        final fixture = await _pumpReader(tester, markdown, platform);
        await _selectFirstWord(tester);
        await _swipe(tester, const Offset(0, -72));
        expect(_canCopy(tester), isTrue);
        fixture.selectionChanges.clear();
        await tester.pump(const Duration(milliseconds: 400));

        final viewport = tester.getRect(_viewport);
        await tester.tapAt(viewport.center + const Offset(25, 100));
        await tester.pumpAndSettle();

        expect(_canCopy(tester), isFalse);
        expect(fixture.selectionChanges, contains(false));
        expect(tester.takeException(), isNull);
      });

      testWidgets('$label Select all still copies off-screen text after swipes', (
        tester,
      ) async {
        final fixture = await _pumpReader(tester, markdown, platform);
        final region = tester.state<SelectableRegionState>(_regionFinder);
        region.selectAll(SelectionChangedCause.toolbar);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 400));
        for (var i = 0; i < 5; i++) {
          await _swipe(tester, const Offset(0, -220));
        }
        expect(fixture.scroll.offset, greaterThan(500));
        expect(
          find.byKey(const ValueKey<String>('reader_text_chunk_119')),
          findsNothing,
        );
        expect(_canCopy(tester), isTrue);
        // Do NOT call selectAll again: this checks the same selection/revision.
        expect(
          await fixture.copy(tester),
          markdown
              ? markdownSelectionText(fixture.document.text)
              : fixture.document.text,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('$label pointer cancellation preserves selection but not taps', (
        tester,
      ) async {
        final fixture = await _pumpReader(tester, markdown, platform);
        await _selectFirstWord(tester);
        fixture.selectionChanges.clear();
        final point = tester.getCenter(_viewport) + const Offset(20, 90);
        final gesture = await tester.startGesture(point);
        await tester.pump(const Duration(milliseconds: 20));
        await gesture.cancel();
        await tester.pumpAndSettle();
        expect(_canCopy(tester), isTrue);
        expect(fixture.selectionChanges, isNot(contains(false)));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tapAt(point);
        await tester.pumpAndSettle();
        expect(_canCopy(tester), isFalse);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$label genuine focus loss still clears during a pointer', (
        tester,
      ) async {
        final fixture = await _pumpReader(tester, markdown, platform);
        await _selectFirstWord(tester);
        fixture.selectionChanges.clear();
        final gesture = await tester.startGesture(tester.getCenter(_viewport));
        final region = tester.widget<SelectableRegion>(_regionFinder);
        region.focusNode!.unfocus();
        await tester.pump();
        await tester.pump();
        expect(_canCopy(tester), isFalse);
        expect(fixture.selectionChanges, contains(false));
        await gesture.cancel();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('$format stylus scroll does not clear the existing selection', (
      tester,
    ) async {
      final fixture = await _pumpReader(tester, markdown, TargetPlatform.android);
      await _selectFirstWord(tester);
      fixture.selectionChanges.clear();
      await _swipe(tester, const Offset(0, -72), kind: PointerDeviceKind.stylus);
      expect(fixture.scroll.offset, greaterThan(0));
      expect(fixture.selectionChanges, isNot(contains(false)));
      expect(await fixture.copy(tester), 'Alpha');
      expect(tester.takeException(), isNull);
    });
  }
}

bool _canCopy(WidgetTester tester) => tester
    .state<SelectableRegionState>(_regionFinder)
    .contextMenuButtonItems
    .any((item) => item.type == ContextMenuButtonType.copy);

Future<void> _selectFirstWord(WidgetTester tester) async {
  final firstParagraph = find.descendant(
    of: find.byKey(const ValueKey<String>('reader_text_chunk_0')),
    matching: find.byType(RichText),
  ).first;
  final paragraph = tester.renderObject<RenderParagraph>(firstParagraph);
  final box = paragraph.getBoxesForSelection(
    const TextSelection(baseOffset: 0, extentOffset: 5),
  ).first;
  await tester.longPressAt(paragraph.localToGlobal(box.toRect().center));
  await tester.pumpAndSettle();
  expect(_canCopy(tester), isTrue);
  // Start a new gesture sequence, not a double/triple tap sequence.
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _swipe(
  WidgetTester tester,
  Offset delta, {
  PointerDeviceKind kind = PointerDeviceKind.touch,
}) async {
  final rect = tester.getRect(_viewport);
  final gesture = await tester.startGesture(
    rect.center + const Offset(30, 100),
    kind: kind,
  );
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.moveBy(delta / 2);
  await tester.pump(const Duration(milliseconds: 40));
  await gesture.moveBy(delta / 2);
  await tester.pump(const Duration(milliseconds: 40));
  // Hold still before lifting to avoid flinging the word off screen in tests
  // that exercise range-copy. The drag recognizer still wins the real arena.
  await gesture.moveBy(const Offset(0, -0.1));
  await tester.pump(const Duration(milliseconds: 180));
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<_ReaderFixture> _pumpReader(
  WidgetTester tester,
  bool markdown,
  TargetPlatform platform,
) async {
  tester.view.physicalSize = const Size(420, 840);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final chunks = <TextDocumentChunk>[];
  final text = StringBuffer();
  for (var index = 0; index < 120; index++) {
    final source = '${markdown ? '**Alpha**' : 'Alpha'} marker $index. '
        '${List<String>.filled(12, 'A readable line for scrolling.').join(' ')}\n\n';
    chunks.add(TextDocumentChunk(startOffset: text.length, text: source));
    text.write(source);
  }
  final document = TextDocument(
    text: text.toString(),
    chunks: chunks,
    encoding: TextDocumentEncoding.utf8,
    isMarkdown: markdown,
  );
  final renderer = TextDocumentRenderer(
    document: DocumentEntry(
      id: 'scroll-selection',
      source: const FileDocumentSource('/selection-test'),
      name: markdown ? 'Selection.md' : 'Selection.txt',
      format: markdown ? DocumentFormat.markdown : DocumentFormat.txt,
      sizeBytes: document.text.length,
      modifiedAt: DateTime.utc(2026, 9, 19),
    ),
    loader: TextDocumentLoader(
      MemoryDocumentContentSource(<String, Uint8List>{}),
    ),
  )
    ..content = document
    ..loadState = ReaderLoadState.ready;
  final fixture = _ReaderFixture(document, AutoScrollController());
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        fixture.copied = (call.arguments as Map)['text'] as String;
      }
      if (call.method == 'Clipboard.hasStrings') {
        return <String, bool>{'value': false};
      }
      return null;
    },
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.scroll.dispose();
    renderer.dispose();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      home: Scaffold(
        body: TextDocumentView(
          renderer: renderer,
          scrollController: fixture.scroll,
          activeHitKey: GlobalKey(),
          onSelectionChanged: fixture.selectionChanges.add,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(
    tester.widget<ListView>(_viewport).keyboardDismissBehavior,
    ScrollViewKeyboardDismissBehavior.manual,
  );
  return fixture;
}

class _ReaderFixture {
  _ReaderFixture(this.document, this.scroll);

  final TextDocument document;
  final AutoScrollController scroll;
  final List<bool> selectionChanges = <bool>[];
  String? copied;

  Future<String?> copy(WidgetTester tester) async {
    final region = tester.state<SelectableRegionState>(_regionFinder);
    final widget = tester.widget<SelectableRegion>(_regionFinder);
    final toolbar = widget.contextMenuBuilder!(
      tester.element(_regionFinder),
      region,
    ) as FolioSelectionToolbar;
    toolbar.buttonItems
        .firstWhere((item) => item.type == ContextMenuButtonType.copy)
        .onPressed!();
    await tester.pumpAndSettle();
    return copied;
  }
}
