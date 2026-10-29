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
import 'package:folio/features/reader/text/logic/text_document_renderer.dart';
import 'package:folio/features/reader/text/widgets/text_document_view.dart';
import 'package:folio/shared/selection/folio_selection_toolbar.dart';
import 'package:folio/shared/selection/selection_visuals.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

final _regionFinder = find.byWidgetPredicate(
  (widget) => widget is SelectableRegion,
);
final _viewport = find.byKey(const ValueKey<String>('reader_content'));

void main() {
  testWidgets('same handle ignores a second pointer', (tester) async {
    await _pumpReader(tester, false, TargetPlatform.android);
    await _selectFirstWord(tester);
    final handles = find.byKey(const ValueKey('reader_selection_handle'));
    final first = await tester.startGesture(
      tester.getCenter(handles.last),
      pointer: 81,
    );
    await first.moveBy(const Offset(45, 30));
    await tester.pump();
    final region = tester.state<SelectableRegionState>(_regionFinder);
    final before = region.selectionEndpoints.map((e) => e.point).toList();
    final second = await tester.startGesture(
      tester.getCenter(handles.last),
      pointer: 82,
    );
    await second.moveBy(const Offset(0, 90));
    await tester.pump();
    final after = region.selectionEndpoints.map((e) => e.point).toList();
    await second.up();
    await first.up();
    await tester.pumpAndSettle();
    expect(
      after,
      before,
      reason: 'second pointer must not take over an active handle',
    );
  });

  testWidgets('inactive cancellation does not reopen the handle menu', (
    tester,
  ) async {
    await _pumpReader(tester, false, TargetPlatform.android);
    await _selectFirstWord(tester);
    final handles = find.byKey(const ValueKey('reader_selection_handle'));
    final gesture = await tester.startGesture(
      tester.getCenter(handles.last),
      pointer: 73,
    );
    await gesture.moveBy(const Offset(45, 30));
    await tester.pump();
    expect(find.byKey(const ValueKey('folio_toolbar_copy')), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await gesture.cancel();
    await tester.pumpAndSettle();
    final reopened = find
        .byKey(const ValueKey('folio_toolbar_copy'))
        .evaluate()
        .length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(
      reopened,
      0,
      reason: 'a lifecycle-canceled drag must not show a fresh context menu',
    );
  });
  testWidgets('second handle cannot drive the first handle', (tester) async {
    await _pumpReader(tester, false, TargetPlatform.android);
    await _selectFirstWord(tester);
    final handles = find.byKey(const ValueKey('reader_selection_handle'));
    final first = await tester.startGesture(
      tester.getCenter(handles.first),
      pointer: 71,
    );
    await first.moveBy(const Offset(-35, 30));
    await tester.pump();
    final region = tester.state<SelectableRegionState>(_regionFinder);
    final before = region.selectionEndpoints.map((e) => e.point).toList();
    final second = await tester.startGesture(
      tester.getCenter(handles.last),
      pointer: 72,
    );
    await second.moveBy(const Offset(25, 90));
    await tester.pump();
    final after = region.selectionEndpoints.map((e) => e.point).toList();
    await second.up();
    await first.up();
    await tester.pumpAndSettle();
    expect(
      after,
      before,
      reason:
          'a rejected second handle must not mutate the active first endpoint',
    );
  });

  testWidgets('collapsing a custom handle updates the reader selection state', (
    tester,
  ) async {
    final fixture = await _pumpReader(tester, false, TargetPlatform.android);
    await _selectFirstWord(tester);
    fixture.selectionChanges.clear();
    final region = tester.state<SelectableRegionState>(_regionFinder);
    final delta =
        region.selectionEndpoints.first.point -
        region.selectionEndpoints.last.point;
    final handle = find.byKey(const ValueKey('reader_selection_handle')).last;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(delta);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(fixture.selectionChanges, contains(false));
    expect(find.byKey(const ValueKey('folio_toolbar_copy')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('handle edge scrolling pulses per line rather than per frame', (
    tester,
  ) async {
    final fixture = await _pumpReader(tester, false, TargetPlatform.android);
    await _selectFirstWord(tester);
    var pulses = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') pulses++;
        return null;
      },
    );
    final handle = find.byKey(const ValueKey('reader_selection_handle')).last;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    final viewport = tester.getRect(_viewport);
    await gesture.moveTo(Offset(viewport.center.dx, viewport.bottom - 18));
    await tester.pump();
    pulses = 0;
    final before = fixture.scroll.offset;
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(fixture.scroll.offset - before, greaterThan(100));
    expect(pulses, inInclusiveRange(2, 20));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'first long-press drag extends by whole words with haptic feedback',
    (tester) async {
      await _pumpReader(tester, false, TargetPlatform.android);
      final pulses = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            pulses.add(call.arguments as String);
          }
          return null;
        },
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find
            .descendant(
              of: find.byKey(const ValueKey<String>('reader_text_chunk_0')),
              matching: find.byType(RichText),
            )
            .first,
      );
      Offset character(int index) => paragraph.localToGlobal(
        paragraph
            .getBoxesForSelection(
              TextSelection(baseOffset: index, extentOffset: index + 1),
            )
            .first
            .toRect()
            .center,
      );
      final gesture = await tester.startGesture(character(1));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
      final initialPulses = pulses.length;
      // A finger sliding inside the selected word must keep the word intact.
      for (final index in <int>[2, 4, 3]) {
        await gesture.moveTo(character(index));
        await tester.pump(const Duration(milliseconds: 32));
      }
      expect(pulses.length, initialPulses);
      // Crossing word boundaries extends the selection word by word.
      // "Alpha" spans 0..5, "marker" 6..12 and "0" starts at 13.
      for (final index in <int>[7, 13]) {
        await gesture.moveTo(character(index));
        await tester.pump(const Duration(milliseconds: 32));
      }
      expect(pulses.length - initialPulses, greaterThanOrEqualTo(2));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selection scrolls while a stationary finger holds inside the edge',
    (tester) async {
      final fixture = await _pumpReader(tester, false, TargetPlatform.android);
      final paragraph = tester.renderObject<RenderParagraph>(
        find
            .descendant(
              of: find.byKey(const ValueKey<String>('reader_text_chunk_0')),
              matching: find.byType(RichText),
            )
            .first,
      );
      final gesture = await tester.startGesture(
        paragraph.localToGlobal(
          paragraph
              .getBoxesForSelection(
                const TextSelection(baseOffset: 0, extentOffset: 5),
              )
              .first
              .toRect()
              .center,
        ),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
      final viewport = tester.getRect(_viewport);
      await gesture.moveTo(Offset(viewport.center.dx, viewport.bottom - 18));
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(fixture.scroll.offset, greaterThan(25));
      expect(fixture.scroll.offset, lessThan(500));
      final region = tester.state<SelectableRegionState>(_regionFinder);
      expect(region.selectionEndpoints, hasLength(2));
      await gesture.up();
      await tester.pumpAndSettle();
      final stopped = fixture.scroll.offset;
      await tester.pump(const Duration(seconds: 2));
      expect(fixture.scroll.offset, stopped);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Markdown copy retains an anchor after its lazy chunk scrolls out',
    (tester) async {
      final fixture = await _pumpReader(tester, true, TargetPlatform.android);
      final paragraph = tester.renderObject<RenderParagraph>(
        find
            .descendant(
              of: find.byKey(const ValueKey<String>('reader_text_chunk_0')),
              matching: find.byType(RichText),
            )
            .first,
      );
      final gesture = await tester.startGesture(
        paragraph.localToGlobal(
          paragraph
              .getBoxesForSelection(
                const TextSelection(baseOffset: 0, extentOffset: 5),
              )
              .first
              .toRect()
              .center,
        ),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
      final viewport = tester.getRect(_viewport);
      await gesture.moveTo(Offset(viewport.center.dx, viewport.bottom - 18));
      for (var frame = 0; frame < 480; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('reader_text_chunk_0')),
        findsNothing,
      );
      final copied = await fixture.copy(tester);
      expect(copied, startsWith('**Alpha** marker 0. '));
      expect(copied, contains('**Alpha** marker 2.'));
      expect(copied!.length, lessThan(fixture.document.text.length));
      expect(tester.takeException(), isNull);
    },
  );

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
        expect(await fixture.copy(tester), markdown ? '**Alpha**' : 'Alpha');
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

      testWidgets(
        '$label Select all still copies off-screen text after swipes',
        (tester) async {
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
          expect(await fixture.copy(tester), fixture.document.text);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        '$label pointer cancellation preserves selection but not taps',
        (tester) async {
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
        },
      );

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
      final fixture = await _pumpReader(
        tester,
        markdown,
        TargetPlatform.android,
      );
      await _selectFirstWord(tester);
      fixture.selectionChanges.clear();
      await _swipe(
        tester,
        const Offset(0, -72),
        kind: PointerDeviceKind.stylus,
      );
      expect(fixture.scroll.offset, greaterThan(0));
      expect(fixture.selectionChanges, isNot(contains(false)));
      expect(await fixture.copy(tester), markdown ? '**Alpha**' : 'Alpha');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('MD heading and body paint a single continued silhouette', (
    tester,
  ) async {
    // Runs through TextDocumentView so the app's real stylesheet is used:
    // 17 px body with height 1.58, 30 px heading with height 1.18, 13 px
    // block spacing. The heading used to be orphaned from its paragraph.
    tester.view.physicalSize = const Size(420, 840);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const source =
        '# Chapter title\n\n'
        'First body paragraph with words in it.\n\n'
        'Second body paragraph with more words.';
    final document = TextDocument(
      text: source,
      chunks: const <TextDocumentChunk>[
        TextDocumentChunk(startOffset: 0, text: source),
      ],
      encoding: TextDocumentEncoding.utf8,
      isMarkdown: true,
    );
    final renderer =
        TextDocumentRenderer(
            document: DocumentEntry(
              id: 'heading-selection',
              source: const FileDocumentSource('/heading-test'),
              name: 'Heading.md',
              format: DocumentFormat.markdown,
              sizeBytes: source.length,
              modifiedAt: DateTime.utc(2026, 9, 19),
            ),
            loader: TextDocumentLoader(
              MemoryDocumentContentSource(<String, Uint8List>{}),
            ),
          )
          ..content = document
          ..loadState = ReaderLoadState.ready;
    final scroll = AutoScrollController();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      scroll.dispose();
      renderer.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: TextDocumentView(
            renderer: renderer,
            scrollController: scroll,
            activeHitKey: GlobalKey(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final heading = tester.getRect(find.text('Chapter title'));
    final body = tester.getRect(
      find.text('First body paragraph with words in it.'),
    );
    final gesture = await tester.startGesture(
      heading.centerLeft + const Offset(2, 0),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(body.center);
    await gesture.up();
    await tester.pumpAndSettle();

    final paint = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.foregroundPainter is FolioSelectionHighlightPainter,
      ),
    );
    final rects = (paint.foregroundPainter! as FolioSelectionHighlightPainter)
        .visibleRects();
    expect(rects.length, greaterThanOrEqualTo(2));
    expect(folioSelectionPath(rects).computeMetrics().length, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('a list marker paints with its own line, not as a side bar', (
    tester,
  ) async {
    // The bullet is its own text widget hanging 8 px into the indent. Joining
    // fragments only within 2 px painted it as a separate strip beside the item
    // text, and consecutive bullets merged into one long bar at the margin.
    tester.view.physicalSize = const Size(420, 840);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const source =
        '- First list item with words in it\n'
        '- Second list item with more words\n';
    final document = TextDocument(
      text: source,
      chunks: const <TextDocumentChunk>[
        TextDocumentChunk(startOffset: 0, text: source),
      ],
      encoding: TextDocumentEncoding.utf8,
      isMarkdown: true,
    );
    final renderer =
        TextDocumentRenderer(
            document: DocumentEntry(
              id: 'list-selection',
              source: const FileDocumentSource('/list-test'),
              name: 'List.md',
              format: DocumentFormat.markdown,
              sizeBytes: source.length,
              modifiedAt: DateTime.utc(2026, 9, 19),
            ),
            loader: TextDocumentLoader(
              MemoryDocumentContentSource(<String, Uint8List>{}),
            ),
          )
          ..content = document
          ..loadState = ReaderLoadState.ready;
    final scroll = AutoScrollController();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      scroll.dispose();
      renderer.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: TextDocumentView(
            renderer: renderer,
            scrollController: scroll,
            activeHitKey: GlobalKey(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final marker = tester.getRect(find.text('•').first);
    final item = tester.getRect(find.text('First list item with words in it'));
    expect(marker.right, lessThan(item.left));
    final gesture = await tester.startGesture(
      marker.centerLeft + const Offset(1, 0),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(item.center);
    await gesture.up();
    await tester.pumpAndSettle();

    final paint = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.foregroundPainter is FolioSelectionHighlightPainter,
      ),
    );
    final rects = (paint.foregroundPainter! as FolioSelectionHighlightPainter)
        .visibleRects();
    expect(rects, isNotEmpty);
    // A point in the gap between the bullet and its text: only reachable when
    // the marker and the line were joined into one silhouette.
    final seam = Offset((marker.right + item.left) / 2, marker.center.dy);
    expect(
      folioSelectionPath(rects).contains(seam),
      isTrue,
      reason: 'the marker must be part of its line',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('== highlights render as marked text and copy with markers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 840);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const source = 'Plain ==marked== tail.';
    final document = TextDocument(
      text: source,
      chunks: const <TextDocumentChunk>[
        TextDocumentChunk(startOffset: 0, text: source),
      ],
      encoding: TextDocumentEncoding.utf8,
      isMarkdown: true,
    );
    final renderer =
        TextDocumentRenderer(
            document: DocumentEntry(
              id: 'mark-selection',
              source: const FileDocumentSource('/mark-test'),
              name: 'Mark.md',
              format: DocumentFormat.markdown,
              sizeBytes: source.length,
              modifiedAt: DateTime.utc(2026, 9, 19),
            ),
            loader: TextDocumentLoader(
              MemoryDocumentContentSource(<String, Uint8List>{}),
            ),
          )
          ..content = document
          ..loadState = ReaderLoadState.ready;
    final scroll = AutoScrollController();
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
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      scroll.dispose();
      renderer.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: TextDocumentView(
            renderer: renderer,
            scrollController: scroll,
            activeHitKey: GlobalKey(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The mark parses into its own span; literal == never reaches the text.
    expect(find.text('marked'), findsOneWidget);
    expect(find.textContaining('=='), findsNothing);

    await tester.longPressAt(tester.getCenter(find.text('marked')));
    await tester.pumpAndSettle();
    final region = tester.state<SelectableRegionState>(_regionFinder);
    final toolbar =
        tester.widget<SelectableRegion>(_regionFinder).contextMenuBuilder!(
          tester.element(_regionFinder),
          region,
        ) as FolioSelectionToolbar;
    toolbar.buttonItems
        .firstWhere((item) => item.type == ContextMenuButtonType.copy)
        .onPressed!();
    await tester.pumpAndSettle();
    expect(copied, '==marked==');
    expect(tester.takeException(), isNull);
  });
}

bool _canCopy(WidgetTester tester) => tester
    .state<SelectableRegionState>(_regionFinder)
    .contextMenuButtonItems
    .any((item) => item.type == ContextMenuButtonType.copy);

Future<void> _selectFirstWord(WidgetTester tester) async {
  final firstParagraph = find
      .descendant(
        of: find.byKey(const ValueKey<String>('reader_text_chunk_0')),
        matching: find.byType(RichText),
      )
      .first;
  final paragraph = tester.renderObject<RenderParagraph>(firstParagraph);
  final box = paragraph
      .getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 5))
      .first;
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
    final source =
        '${markdown ? '**Alpha**' : 'Alpha'} marker $index. '
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
  final renderer =
      TextDocumentRenderer(
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
