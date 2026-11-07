import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_tutorial_store.dart';

import 'package:folio/app/folio_app.dart';
import 'package:folio/features/library/data/in_memory_library_repository.dart';
import 'package:folio/features/settings/widgets/folio_settings_sheet.dart';
import 'package:folio/shared/glass/widgets/liquid_glass_toggle.dart';
import 'package:folio/shared/glass/surface/glass_panel.dart';
import 'package:folio/shared/settings/folio_settings_controller.dart';
import 'package:folio/shared/settings/folio_settings_scope.dart';

import '../../support/memory_settings_store.dart';

void main() {
  testWidgets('header opens one settings sheet and switches are independent', (
    tester,
  ) async {
    final store = MemorySettingsStore();
    await tester.pumpWidget(
      FolioApp(
        tutorialStore: MemoryTutorialStore.allSeen(),
        libraryRepository: InMemoryLibraryRepository.demo(),
        settingsStore: store,
      ),
    );
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey<String>('library_settings'));
    expect(button, findsOneWidget);
    expect(find.text('Folio'), findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byType(FolioSettingsSheet), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    final blur = find.byKey(const ValueKey<String>('settings_blur'));
    final motion = find.byKey(const ValueKey<String>('settings_liquid_motion'));
    final navigation = find.byKey(
      const ValueKey<String>('settings_show_navigation_on_scroll_up'),
    );
    expect(tester.widget<LiquidGlassToggle>(blur).value, isFalse);
    expect(tester.widget<LiquidGlassToggle>(motion).value, isTrue);
    expect(tester.widget<LiquidGlassToggle>(navigation).value, isTrue);
    await tester.tap(blur);
    await tester.pumpAndSettle();
    expect(tester.widget<LiquidGlassToggle>(blur).value, isTrue);
    expect(tester.widget<LiquidGlassToggle>(motion).value, isTrue);
    expect(store.value.blurEnabled, isTrue);
    // The route barrier blurs; the opaque sheet's own filter is a permanent
    // passthrough, so "any" — not "every".
    expect(
      tester
          .widgetList<BackdropFilter>(find.byType(BackdropFilter))
          .any((filter) => filter.enabled),
      isTrue,
    );
    await tester.tap(motion);
    await tester.pumpAndSettle();
    expect(store.value.liquidMotionEnabled, isFalse);
    await tester.ensureVisible(navigation);
    await tester.tap(navigation);
    await tester.pumpAndSettle();
    expect(store.value.showNavigationOnScrollUp, isFalse);
    expect(store.value.blurEnabled, isTrue);
    expect(store.value.liquidMotionEnabled, isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(FolioSettingsSheet), findsNothing);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(tester.widget<LiquidGlassToggle>(blur).value, isTrue);
    expect(tester.widget<LiquidGlassToggle>(motion).value, isFalse);
    expect(tester.widget<LiquidGlassToggle>(navigation).value, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('settings remain usable on a narrow screen with large text', (
    tester,
  ) async {
    final controller = FolioSettingsController(store: MemorySettingsStore());
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      FolioSettingsScope(
        controller: controller,
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(280, 500),
              textScaler: TextScaler.linear(1.6),
            ),
            child: Center(
              child: SizedBox(
                width: 280,
                child: FolioSettingsSheet(controller: controller),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final motion = find.byKey(const ValueKey<String>('settings_liquid_motion'));
    await tester.ensureVisible(motion);
    await tester.tap(motion);
    await tester.pumpAndSettle();
    expect(controller.settings.liquidMotionEnabled, isFalse);
    final navigation = find.byKey(
      const ValueKey<String>('settings_show_navigation_on_scroll_up'),
    );
    await tester.ensureVisible(navigation);
    await tester.tap(navigation);
    await tester.pumpAndSettle();
    expect(controller.settings.showNavigationOnScrollUp, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('blur can be toggled without remounting surface content', (
    tester,
  ) async {
    final controller = FolioSettingsController(store: MemorySettingsStore());
    addTearDown(controller.dispose);
    var mounts = 0;
    await tester.pumpWidget(
      FolioSettingsScope(
        controller: controller,
        child: MaterialApp(
          home: Center(
            child: SizedBox(
              width: 200,
              height: 100,
              child: GlassPanel(child: _MountProbe(onMount: () => mounts++)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.setBlurEnabled(true);
    await tester.pumpAndSettle();
    controller.setBlurEnabled(false);
    await tester.pumpAndSettle();
    controller.setBlurEnabled(true);
    await tester.pumpAndSettle();
    expect(mounts, 1);
    expect(
      tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _MountProbe extends StatefulWidget {
  const _MountProbe({required this.onMount});
  final VoidCallback onMount;

  @override
  State<_MountProbe> createState() => _MountProbeState();
}

class _MountProbeState extends State<_MountProbe> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => const Text('Surface content');
}
