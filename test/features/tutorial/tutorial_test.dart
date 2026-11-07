import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/tutorial/data/tutorial_progress_store.dart';
import 'package:folio/features/tutorial/logic/tutorial_controller.dart';
import 'package:folio/features/tutorial/tutorial_catalog.dart';
import 'package:folio/shared/theme/folio_theme.dart';
import 'package:folio/shared/widgets/info_notice/info_notice_tooltip.dart';

import '../../support/memory_tutorial_store.dart';

void main() {
  setUpAll(() async {
    final inter = FontLoader('Inter')
      ..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await inter.load();
  });

  group('TutorialController', () {
    test('loads persisted progress before offering hints', () async {
      final controller = TutorialController(
        store: MemoryTutorialStore({TutorialTour.externalClose}),
      );
      addTearDown(controller.dispose);

      expect(controller.shouldShow(TutorialTour.pptxOverview), isFalse);
      await controller.load();
      expect(controller.shouldShow(TutorialTour.externalClose), isFalse);
      expect(controller.shouldShow(TutorialTour.pptxOverview), isTrue);
    });

    test(
      'merges a gesture performed while loading with stored progress',
      () async {
        final store = _DelayedTutorialStore();
        final controller = TutorialController(store: store);
        addTearDown(controller.dispose);

        final loading = controller.load();
        controller.complete(TutorialTour.externalClose);
        store.pending.complete({TutorialTour.pptxOverview});
        await loading;
        await Future<void>.delayed(Duration.zero);

        expect(controller.shouldShow(TutorialTour.externalClose), isFalse);
        expect(controller.shouldShow(TutorialTour.pptxOverview), isFalse);
        expect(store.saved, TutorialTour.values.toSet());
      },
    );
  });

  testWidgets('the tooltip caret points at the Close control', (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const target = ValueKey<String>('close');
    await tester.pumpWidget(
      ThemeColors(
        colors: darkAppColors,
        glass: darkGlassColors,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Overlay(
            initialEntries: [
              OverlayEntry(
                builder: (context) => const ColoredBox(
                  color: Color(0xFF1D1E21),
                  child: Stack(
                    children: [
                      Positioned(
                        left: AppSpacing.lg,
                        top: AppSpacing.xxxl,
                        width: AppSpacing.xxxxxl,
                        height: AppSpacing.xxxxxl,
                        child: InfoNoticeTooltip(
                          message:
                              'Press and hold Close.\nChoose '
                              '“Close app” or “Return to main”.',
                          child: DecoratedBox(
                            key: target,
                            decoration: BoxDecoration(
                              color: Color(0xFF292A2D),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byWidgetPredicate(
      (widget) =>
          widget is DecoratedBox && widget.decoration is ShapeDecoration,
    );
    expect(
      tester.getTopLeft(card).dy,
      tester.getBottomLeft(find.byKey(target)).dy + AppSpacing.xs,
    );
    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile('goldens/close_tooltip.png'),
    );

    await tester.binding.setSurfaceSize(const Size(240, 320));
    await tester.pumpAndSettle();
    expect(tester.getRect(card).right, lessThan(240));
    expect(tester.getRect(card).bottom, lessThan(320));
    expect(
      tester.getTopLeft(card).dy,
      tester.getBottomLeft(find.byKey(target)).dy + AppSpacing.xs,
    );
  });

  group('FileTutorialProgressStore', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('folio_tutorial_test');
    });

    tearDown(() {
      directory.deleteSync(recursive: true);
    });

    test('round-trips the seen set through one JSON file', () async {
      final store = FileTutorialProgressStore(
        directoryProvider: () async => directory,
      );
      await store.save({TutorialTour.pptxOverview});
      expect(await store.load(), <TutorialTour>{TutorialTour.pptxOverview});

      // Unknown tour names (forward compatibility) are dropped silently.
      final file = File(
        '${directory.path}${Platform.pathSeparator}folio_tutorial.v1.json',
      );
      await file.writeAsString(
        jsonEncode(<String, Object?>{
          'version': 1,
          'seen': <String>['externalClose', 'ghost'],
        }),
      );
      expect(await store.load(), <TutorialTour>{TutorialTour.externalClose});
    });

    test('a corrupt or missing file falls back to clean progress', () async {
      final store = FileTutorialProgressStore(
        directoryProvider: () async => directory,
      );
      expect(await store.load(), isEmpty);

      final file = File(
        '${directory.path}${Platform.pathSeparator}folio_tutorial.v1.json',
      );
      await file.writeAsString('{broken');
      expect(await store.load(), isEmpty);
    });
  });
}

class _DelayedTutorialStore extends MemoryTutorialStore {
  final pending = Completer<Set<TutorialTour>>();

  @override
  Future<Set<TutorialTour>> load() => pending.future;
}
