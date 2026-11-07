import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/memory_tutorial_store.dart';

import 'package:folio/app/folio_app.dart';
import 'package:folio/features/library/data/in_memory_library_repository.dart';
import 'package:folio/shared/glass/widgets/liquid_search_control.dart';
import 'package:folio/shared/settings/folio_settings.dart';

import '../support/memory_settings_store.dart';

Future<Finder> _pumpLibrary(WidgetTester tester, FolioSettings settings) async {
  await tester.binding.setSurfaceSize(const Size(412, 915));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    FolioApp(
      tutorialStore: MemoryTutorialStore.allSeen(),
      settingsStore: MemorySettingsStore(settings),
      libraryRepository: InMemoryLibraryRepository.demo(),
    ),
  );
  await tester.pumpAndSettle();
  return find.byKey(const ValueKey<String>('folio_surface'));
}

void main() {
  setUpAll(() async {
    final inter = FontLoader('Inter')
      ..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await inter.load();
    final playfair = FontLoader('PlayfairDisplay')
      ..addFont(rootBundle.load('assets/fonts/PlayfairDisplay.ttf'));
    await playfair.load();
  });

  testWidgets('library and liquid search visual states', (tester) async {
    final surface = await _pumpLibrary(tester, const FolioSettings());

    await expectLater(
      surface,
      matchesGoldenFile('library_search_collapsed.png'),
    );

    await tester.tap(find.text('PPTX'));
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 15));
    }
    await expectLater(
      surface,
      matchesGoldenFile('library_filter_morphing.png'),
    );
    await tester.pumpAndSettle();
    await expectLater(
      surface,
      matchesGoldenFile('library_filter_selected.png'),
    );
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();

    final filter = find.byKey(const ValueKey<String>('format_filters'));
    final filterRect = tester.getRect(filter);
    final segmentWidth = filterRect.width / 5;
    final lensGesture = await tester.startGesture(
      Offset(filterRect.left + segmentWidth / 2, filterRect.center.dy),
    );
    await tester.pump(const Duration(milliseconds: 80));
    await lensGesture.moveTo(
      Offset(filterRect.left + segmentWidth * 2.5, filterRect.center.dy),
    );
    await tester.pump(const Duration(milliseconds: 110));
    await expectLater(
      surface,
      matchesGoldenFile('library_filter_dragging.png'),
    );
    await lensGesture.cancel();
    await tester.pumpAndSettle();

    final search = find.byKey(const ValueKey<String>('search_button_hit'));
    final gesture = await tester.startGesture(tester.getCenter(search));
    await tester.pump(const Duration(milliseconds: 80));
    await expectLater(surface, matchesGoldenFile('library_search_pressed.png'));

    await gesture.cancel();
    await tester.pumpAndSettle();
    tester
        .state<LiquidSearchControlState>(find.byType(LiquidSearchControl))
        .open();
    await tester.pump(const Duration(milliseconds: 150));
    await expectLater(
      surface,
      matchesGoldenFile('library_search_morphing.png'),
    );

    await tester.pumpAndSettle();
    await expectLater(
      surface,
      matchesGoldenFile('library_search_expanded.png'),
    );
  });

  testWidgets('light theme restyles the library surface', (tester) async {
    final surface = await _pumpLibrary(
      tester,
      const FolioSettings(themeMode: FolioThemeMode.light),
    );

    await expectLater(surface, matchesGoldenFile('library_light_theme.png'));
  });
}
