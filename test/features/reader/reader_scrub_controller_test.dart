import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/reader/logic/reader_navigation.dart';
import 'package:folio/features/reader/logic/reader_scrub_controller.dart';

/// Fake navigation that records seek dispatches against an injected clock.
class _RecordingNavigation implements ReaderNavigation {
  _RecordingNavigation();

  Duration minimumSeekInterval = Duration.zero;
  final List<double> seeks = <double>[];
  final List<Duration> seekTimes = <Duration>[];
  DateTime Function() now = () => DateTime.utc(2026, 11, 1);

  @override
  ReaderNavigationSnapshot get snapshot => ReaderNavigationSnapshot(
    canSeek: true,
    showScrubber: true,
    positionLabel: 'test',
    confirmedFraction: 0,
    minimumSeekInterval: minimumSeekInterval,
  );

  @override
  String labelForFraction(double fraction) => '${(fraction * 100).round()}%';

  @override
  Future<void> seekToFraction(double fraction) async {
    seeks.add(fraction);
    seekTimes.add(now().difference(DateTime.utc(2026, 11, 1)));
  }

  @override
  void revalidate() {}

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  void dispose() {}
}

void main() {
  late _RecordingNavigation navigation;
  late DateTime fakeNow;
  late ReaderScrubController controller;

  setUp(() {
    navigation = _RecordingNavigation();
    fakeNow = DateTime.utc(2026, 11, 1);
    navigation.now = () => fakeNow;
    controller = ReaderScrubController(navigation, now: () => fakeNow);
  });

  tearDown(() => controller.dispose());

  testWidgets('the first request is dispatched immediately', (tester) async {
    controller.begin(0.3);
    expect(navigation.seeks, <double>[0.3]);
    expect(controller.isScrubbing, isTrue);
    expect(controller.previewFraction, 0.3);
  });

  testWidgets(
    'drag updates dispatch at most once per frame with the latest value',
    (tester) async {
      controller.begin(0.1);
      controller.update(0.2);
      controller.update(0.3);
      controller.update(0.4);
      // Only the immediate begin seek has run; the frame-coalesced flush has
      // not, and no intermediate value may leak through.
      expect(navigation.seeks, <double>[0.1]);
      await tester.pump();
      expect(navigation.seeks, <double>[0.1, 0.4]);
      await tester.pump();
      expect(navigation.seeks, <double>[0.1, 0.4]);
    },
  );

  testWidgets('the heavy policy respects the 80 ms spacing', (tester) async {
    navigation.minimumSeekInterval = const Duration(milliseconds: 80);
    controller.begin(0.1);
    expect(navigation.seeks, <double>[0.1]);

    fakeNow = fakeNow.add(const Duration(milliseconds: 10));
    controller.update(0.5);
    await tester.pump();
    // Too soon after the begin seek: held for the throttle boundary.
    expect(navigation.seeks, <double>[0.1]);

    await tester.pump(const Duration(milliseconds: 80));
    expect(navigation.seeks, <double>[0.1, 0.5]);
  });

  testWidgets('release lands on the newer pending, not the old trailing', (
    tester,
  ) async {
    navigation.minimumSeekInterval = const Duration(milliseconds: 80);
    controller.begin(0.1);

    // A drag inside the throttle window parks 0.5 as the trailing seek.
    fakeNow = fakeNow.add(const Duration(milliseconds: 10));
    controller.update(0.5);
    await tester.pump();
    expect(navigation.seeks, <double>[0.1]);

    // A later drag stores 0.9 as the frame-pending target, newer than the
    // parked trailing value.
    fakeNow = fakeNow.add(const Duration(milliseconds: 10));
    controller.update(0.9);

    controller.end();
    expect(navigation.seeks, <double>[0.1, 0.9]);
    expect(controller.isScrubbing, isFalse);
  });

  testWidgets('release without pending falls back to the trailing seek', (
    tester,
  ) async {
    navigation.minimumSeekInterval = const Duration(milliseconds: 80);
    controller.begin(0.1);
    fakeNow = fakeNow.add(const Duration(milliseconds: 10));
    controller.update(0.6);
    await tester.pump();
    controller.end();
    expect(navigation.seeks, <double>[0.1, 0.6]);
  });

  testWidgets('end after the throttle boundary dispatches the last update', (
    tester,
  ) async {
    navigation.minimumSeekInterval = const Duration(milliseconds: 80);
    controller.begin(0.1);
    fakeNow = fakeNow.add(const Duration(milliseconds: 90));
    controller.update(0.8);
    await tester.pump();
    expect(navigation.seeks, <double>[0.1, 0.8]);
    controller.end();
    // Nothing new arrived after the dispatched update: no duplicate seek.
    expect(navigation.seeks, <double>[0.1, 0.8]);
  });

  testWidgets('cancel and dispose leave no timers or frame callbacks', (
    tester,
  ) async {
    navigation.minimumSeekInterval = const Duration(milliseconds: 80);
    controller.begin(0.1);
    fakeNow = fakeNow.add(const Duration(milliseconds: 10));
    controller.update(0.4);
    await tester.pump();

    // Cancel lands exactly like end: the parked value is delivered once,
    // synchronously.
    controller.cancel();
    expect(controller.isScrubbing, isFalse);
    expect(navigation.seeks, <double>[0.1, 0.4]);

    // Run well past the throttle boundary: the parked timer must not fire
    // a second time.
    await tester.pump(const Duration(seconds: 1));
    expect(navigation.seeks, <double>[0.1, 0.4]);

    // A disposed controller must not keep frame callbacks alive either: the
    // immediate begin seek (0.2) runs, the pending update (0.3) never does.
    final disposedController = ReaderScrubController(
      navigation,
      now: () => fakeNow,
    );
    disposedController.begin(0.2);
    disposedController.update(0.3);
    disposedController.dispose();
    await tester.pump();
    expect(navigation.seeks, <double>[0.1, 0.4, 0.2]);
  });

  testWidgets('update while idle starts a scrub', (tester) async {
    controller.update(0.7);
    expect(controller.isScrubbing, isTrue);
    expect(navigation.seeks, <double>[0.7]);
  });

  testWidgets('preview follows the finger without dispatching per pixel', (
    tester,
  ) async {
    controller.begin(0.1);
    controller.update(0.2);
    controller.update(0.35);
    expect(controller.previewFraction, 0.35);
    expect(navigation.seeks, <double>[0.1]);
    await tester.pump();
    expect(controller.previewFraction, 0.35);
  });

  testWidgets('begin while already scrubbing is ignored', (tester) async {
    controller.begin(0.1);
    controller.begin(0.5);
    expect(navigation.seeks, <double>[0.1]);
    expect(controller.previewFraction, 0.1);
  });

  testWidgets('non-finite targets are ignored', (tester) async {
    controller.begin(double.nan);
    expect(controller.isScrubbing, isTrue);
    expect(controller.previewFraction, 0.0);
    expect(navigation.seeks, <double>[0.0]);
    controller.update(double.infinity);
    await tester.pump();
    expect(navigation.seeks, <double>[0.0]);
  });
}
