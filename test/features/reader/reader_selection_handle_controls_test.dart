import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/reader/text/widgets/reader_selection_handle_controls.dart';

void main() {
  for (final usePadding in <bool>[false, true]) {
    testWidgets(
      'reader owns ${usePadding ? 'padded' : 'visible'} handle drag during scroll',
      (tester) async {
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        final starts = <TextSelectionHandleType>[];
        final updates = <Offset>[];
        var ends = 0;
        final controls = ReaderSelectionHandleControls(
          delegate: materialTextSelectionHandleControls,
          onDragStart: (type, lineHeight, position) {
            expect(lineHeight, greaterThan(0));
            starts.add(type);
          },
          onDragUpdate: updates.add,
          onDragEnd: () => ends++,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SelectionArea(
                selectionControls: controls,
                child: ListView(
                  controller: scroll,
                  children: <Widget>[
                    const SizedBox(height: 100),
                    Text(
                      List.filled(200, 'Alpha beta gamma delta.').join('\n'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final paragraph = tester.renderObject<RenderParagraph>(
          find.byType(RichText).first,
        );
        final firstWord = paragraph
            .getBoxesForSelection(
              const TextSelection(baseOffset: 0, extentOffset: 5),
            )
            .first
            .toRect();
        await tester.longPressAt(paragraph.localToGlobal(firstWord.center));
        await tester.pumpAndSettle();
        expect(
          tester
              .state<SelectableRegionState>(find.byType(SelectableRegion))
              .selectionEndpoints,
          hasLength(2),
        );
        final handle = find
            .byKey(const ValueKey<String>('reader_selection_handle'))
            .last;
        expect(handle, findsOneWidget);
        final rect = tester.getRect(handle);
        final start = usePadding
            ? rect.topCenter - const Offset(0, 5)
            : rect.center;
        final pulses = <Object?>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'HapticFeedback.vibrate') {
              pulses.add(call.arguments);
            }
            return null;
          },
        );
        final gesture = await tester.startGesture(start);
        await gesture.moveBy(const Offset(45, 45));
        await tester.pump();
        await gesture.moveBy(const Offset(5, 5));
        await tester.pump();
        expect(starts, hasLength(1));
        expect(updates, isNotEmpty);
        scroll.jumpTo(25);
        await tester.pump();
        scroll.jumpTo(50);
        await tester.pump();
        expect(pulses, isEmpty);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(ends, 1);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets('cancellation ends a reader handle drag once', (tester) async {
    var ends = 0;
    final controls = ReaderSelectionHandleControls(
      delegate: materialTextSelectionHandleControls,
      onDragStart: (_, _, _) {},
      onDragUpdate: (_) {},
      onDragEnd: () => ends++,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: controls.buildHandle(
              context,
              TextSelectionHandleType.right,
              20,
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('reader_selection_handle'))),
    );
    await gesture.moveBy(const Offset(40, 20));
    await tester.pump();
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(ends, 1);
  });

  testWidgets('platform handle taps keep their native callback', (
    tester,
  ) async {
    var taps = 0;
    final controls = ReaderSelectionHandleControls(
      delegate: materialTextSelectionHandleControls,
      onDragStart: (_, _, _) => fail('A tap must not start a handle drag.'),
      onDragUpdate: (_) => fail('A tap must not update a handle drag.'),
      onDragEnd: () => fail('A tap must not end a handle drag.'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: controls.buildHandle(
              context,
              TextSelectionHandleType.right,
              20,
              () => taps++,
            ),
          ),
        ),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('reader_selection_handle')),
    );
    expect(taps, 1);
  });

  test('platform geometry remains unchanged', () {
    final controls = ReaderSelectionHandleControls(
      delegate: materialTextSelectionHandleControls,
      onDragStart: (_, _, _) {},
      onDragUpdate: (_) {},
      onDragEnd: () {},
    );
    for (final type in TextSelectionHandleType.values) {
      expect(
        controls.getHandleAnchor(type, 24),
        materialTextSelectionHandleControls.getHandleAnchor(type, 24),
      );
      expect(
        controls.getHandleSize(24),
        materialTextSelectionHandleControls.getHandleSize(24),
      );
    }
    expect(controls, isA<TextSelectionHandleControls>());
  });
}
