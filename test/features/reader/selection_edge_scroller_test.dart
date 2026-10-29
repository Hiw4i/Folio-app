import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/reader/logic/selection_edge_scroller.dart';

void main() {
  testWidgets('a stationary point inside the bottom edge keeps scrolling', (
    tester,
  ) async {
    final fixture = await _pumpScroller(tester);
    fixture.scroller.update(
      Offset(fixture.bounds.center.dx, fixture.bounds.bottom - 28),
    );
    await tester.pump();
    await _advance(tester, const Duration(milliseconds: 600));

    expect(fixture.scroll.offset, closeTo(932, 1));
    final before = fixture.scroll.offset;
    await _advance(tester, const Duration(milliseconds: 200));
    expect(fixture.scroll.offset - before, closeTo(144, 1));
    expect(fixture.scrollNotifications, greaterThan(1));
  });

  testWidgets('edge speed waits before a smooth and bounded hold ramp', (
    tester,
  ) async {
    final fixture = await _pumpScroller(tester);
    fixture.scroller.update(fixture.bounds.bottomCenter + const Offset(0, 80));
    await tester.pump();
    await _advance(tester, const Duration(milliseconds: 400));
    final first = fixture.scroll.offset - 500;
    await _advance(tester, const Duration(milliseconds: 400));
    final second = fixture.scroll.offset - 500 - first;
    expect(first, closeTo(400, 0.5));
    expect(second, closeTo(first, 0.5));

    final beforeRamp = fixture.scroll.offset;
    await _advance(tester, const Duration(milliseconds: 200));
    expect(fixture.scroll.offset - beforeRamp, inInclusiveRange(200, 202));
    await _advance(tester, const Duration(milliseconds: 1500));
    final beforeMaximum = fixture.scroll.offset;
    await _advance(tester, const Duration(milliseconds: 400));
    expect(fixture.scroll.offset - beforeMaximum, closeTo(640, 0.5));
  });

  testWidgets('leaving the edge stops frames and resets the hold ramp', (
    tester,
  ) async {
    final fixture = await _pumpScroller(tester);
    fixture.scroller.update(fixture.bounds.bottomCenter);
    await tester.pump();
    await _advance(tester, const Duration(milliseconds: 2500));
    fixture.scroller.update(fixture.bounds.center);
    final stoppedOffset = fixture.scroll.offset;
    final notifications = fixture.scrollNotifications;
    await _advance(tester, const Duration(seconds: 1));
    expect(fixture.scroll.offset, stoppedOffset);
    expect(fixture.scrollNotifications, notifications);
    expect(tester.binding.transientCallbackCount, 0);

    fixture.scroller.update(fixture.bounds.bottomCenter);
    await tester.pump();
    await _advance(tester, const Duration(milliseconds: 400));
    expect(fixture.scroll.offset - stoppedOffset, closeTo(400, 0.5));
  });

  testWidgets('selection event replays preserve a held edge ramp', (
    tester,
  ) async {
    final fixture = await _pumpScroller(tester);
    fixture.scroller.update(fixture.bounds.bottomCenter);
    await tester.pump();
    for (var frame = 0; frame < 250; frame++) {
      fixture.scroller.update(fixture.bounds.bottomCenter);
      await tester.pump(const Duration(milliseconds: 10));
    }
    final before = fixture.scroll.offset;
    await _advance(tester, const Duration(milliseconds: 400));
    expect(fixture.scroll.offset - before, closeTo(640, 0.5));
  });

  testWidgets('changing edge direction resets the hold ramp', (tester) async {
    final fixture = await _pumpScroller(tester, initialOffset: 1000);
    fixture.scroller.update(fixture.bounds.bottomCenter);
    await tester.pump();
    await _advance(tester, const Duration(milliseconds: 2500));
    final before = fixture.scroll.offset;
    fixture.scroller.update(fixture.bounds.topCenter);
    await tester.pump();
    await _advance(tester, const Duration(milliseconds: 400));
    expect(before - fixture.scroll.offset, closeTo(400, 0.5));
  });

  testWidgets('reaching an extent releases the ticker without overscroll', (
    tester,
  ) async {
    final fixture = await _pumpScroller(tester, initialOffset: 10);
    fixture.scroller.update(fixture.bounds.topCenter);
    await tester.pump();
    await _advance(tester, const Duration(milliseconds: 300));
    expect(fixture.scroll.offset, 0);
    expect(tester.binding.transientCallbackCount, 0);
    final notifications = fixture.scrollNotifications;
    await _advance(tester, const Duration(seconds: 1));
    fixture.scroller.update(fixture.bounds.topCenter);
    await tester.pump();
    expect(fixture.scrollNotifications, notifications);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('physical edges follow reversed and horizontal scroll axes', (
    tester,
  ) async {
    final reversed = await _pumpScroller(tester, reverse: true);
    reversed.scroller.update(reversed.bounds.topCenter);
    await tester.pump();
    await _advance(tester, const Duration(milliseconds: 400));
    expect(reversed.scroll.offset, closeTo(900, 0.5));
    reversed.scroller.stop();

    final horizontal = await _pumpScroller(tester, axis: Axis.horizontal);
    horizontal.scroller.update(horizontal.bounds.centerRight);
    await tester.pump();
    await _advance(tester, const Duration(milliseconds: 400));
    expect(horizontal.scroll.offset, closeTo(900, 0.5));
  });

  testWidgets('normal frame cadences cover the same distance', (tester) async {
    final fixture = await _pumpScroller(tester);
    fixture.scroller.update(fixture.bounds.bottomCenter);
    await tester.pump();
    await _advance(
      tester,
      const Duration(milliseconds: 800),
      step: const Duration(milliseconds: 8),
    );
    final highRefreshDistance = fixture.scroll.offset - 500;
    fixture.scroller.stop();
    fixture.scroll.jumpTo(500);
    fixture.scroller.update(fixture.bounds.bottomCenter);
    await tester.pump();
    await _advance(
      tester,
      const Duration(milliseconds: 800),
      step: const Duration(milliseconds: 32),
    );
    expect(fixture.scroll.offset - 500, closeTo(highRefreshDistance, 0.5));
  });

  testWidgets('a stalled frame cannot create a large scroll jump', (
    tester,
  ) async {
    final fixture = await _pumpScroller(tester);
    fixture.scroller.update(fixture.bounds.bottomCenter);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(fixture.scroll.offset - 500, inExclusiveRange(0, 88));
  });

  testWidgets('invalid geometry, detachment, and disposal stop scrolling', (
    tester,
  ) async {
    final fixture = await _pumpScroller(tester);
    fixture.scroller.update(fixture.bounds.bottomCenter);
    await tester.pump();
    fixture.viewport = null;
    await tester.pump(const Duration(milliseconds: 20));
    expect(tester.binding.transientCallbackCount, 0);
    fixture.viewport = Rect.zero;
    fixture.scroller.update(Offset.zero);
    fixture.viewport = const Rect.fromLTRB(0, 0, double.infinity, 200);
    fixture.scroller.update(Offset.zero);
    fixture.viewport = fixture.bounds;
    fixture.scroller.update(const Offset(double.nan, 100));
    expect(tester.binding.transientCallbackCount, 0);

    fixture.scroller.update(fixture.bounds.bottomCenter);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
    expect(tester.binding.transientCallbackCount, 0);
    fixture.scroller.dispose();
    fixture.scroller.update(fixture.bounds.bottomCenter);
    fixture.scroller.stop();
    fixture.scroller.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a controller attached to multiple viewports is ignored', (
    tester,
  ) async {
    final fixture = await _pumpScroller(tester, multiplePositions: true);
    fixture.scroller.update(fixture.bounds.bottomCenter);
    await tester.pump();
    await _advance(tester, const Duration(milliseconds: 200));
    expect(fixture.scroll.positions, hasLength(2));
    expect(
      fixture.scroll.positions.map((position) => position.pixels),
      <double>[500, 500],
    );
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing an active scroll releases pending frames', (
    tester,
  ) async {
    final fixture = await _pumpScroller(tester);
    fixture.scroller.update(fixture.bounds.bottomCenter);
    await tester.pump();
    await _advance(tester, const Duration(milliseconds: 100));
    final before = fixture.scroll.offset;
    fixture.scroller.dispose();
    await _advance(tester, const Duration(seconds: 1));
    expect(fixture.scroll.offset, before);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('scroll listeners may dispose before the replay callback', (
    tester,
  ) async {
    final fixture = await _pumpScroller(tester);
    fixture.scroll.addListener(fixture.scroller.dispose);
    fixture.scroller.update(fixture.bounds.bottomCenter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(fixture.scroll.offset, greaterThan(500));
    expect(fixture.scrollNotifications, 0);
    expect(tester.binding.transientCallbackCount, 0);
  });
}

Future<void> _advance(
  WidgetTester tester,
  Duration duration, {
  Duration step = const Duration(milliseconds: 10),
}) async {
  var remaining = duration;
  while (remaining > Duration.zero) {
    final frame = remaining < step ? remaining : step;
    await tester.pump(frame);
    remaining -= frame;
  }
}

Future<_ScrollerFixture> _pumpScroller(
  WidgetTester tester, {
  double initialOffset = 500,
  bool reverse = false,
  Axis axis = Axis.vertical,
  bool multiplePositions = false,
}) async {
  final scroll = ScrollController(initialScrollOffset: initialOffset);
  final fixture = _ScrollerFixture(scroll);
  final viewportKey = GlobalKey();
  Widget list({Key? key}) => SizedBox(
    key: key,
    width: 320,
    height: 400,
    child: ListView.builder(
      controller: scroll,
      scrollDirection: axis,
      reverse: reverse,
      itemExtent: 40,
      itemCount: 200,
      itemBuilder: (_, index) => Text('Line $index'),
    ),
  );

  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: multiplePositions
            ? Row(
                children: <Widget>[
                  list(key: viewportKey),
                  list(),
                ],
              )
            : list(key: viewportKey),
      ),
    ),
  );
  fixture.bounds = tester.getRect(find.byKey(viewportKey));
  fixture.viewport = fixture.bounds;
  fixture.scroller = SelectionEdgeScroller(
    vsync: tester,
    scrollController: () => scroll,
    viewport: () => fixture.viewport,
    onScrolled: () => fixture.scrollNotifications++,
  );
  addTearDown(() async {
    fixture.scroller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
  });
  return fixture;
}

class _ScrollerFixture {
  _ScrollerFixture(this.scroll);

  final ScrollController scroll;
  late final SelectionEdgeScroller scroller;
  late final Rect bounds;
  Rect? viewport;
  int scrollNotifications = 0;
}
