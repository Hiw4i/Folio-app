import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/shared/glass/widgets/liquid_morphing_control.dart';
import 'package:folio/shared/glass/widgets/adaptive_glass_effects.dart';
import 'package:folio/shared/settings/folio_settings.dart';
import 'package:folio/shared/settings/folio_settings_controller.dart';
import 'package:folio/shared/settings/folio_settings_scope.dart';

import '../../support/memory_settings_store.dart';

void main() {
  Widget buildHarness({
    required ValueChanged<int> onBackgroundDrag,
    VoidCallback? onCollapsedTap,
  }) {
    return MediaQuery(
      data: const MediaQueryData(),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (_) => onBackgroundDrag(1),
            ),
            LiquidMorphingControl(
              collapsedHitKey: const ValueKey<String>('morph_hit'),
              collapsedSemanticsLabel: 'Open menu',
              expandedSemanticsLabel: 'Menu',
              onCollapsedTap: onCollapsedTap,
              geometryBuilder: (size) => LiquidMorphGeometry(
                collapsedRect: const Rect.fromLTWH(300, 20, 48, 48),
                expandedRect: const Rect.fromLTWH(140, 20, 208, 116),
              ),
              collapsedChild: const Center(
                child: AdaptiveGlassDecoration(child: Text('•••')),
              ),
              expandedChild: const Center(
                child: AdaptiveGlassDecoration(child: Text('Menu content')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('morphing glass absorbs a drag before content behind it', (
    tester,
  ) async {
    var backgroundDrags = 0;
    await tester.pumpWidget(
      buildHarness(onBackgroundDrag: (value) => backgroundDrags += value),
    );

    final center = tester.getCenter(
      find.byKey(const ValueKey<String>('morph_hit')),
    );
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(-34, 8));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(backgroundDrags, 0);
  });

  testWidgets('short tap runs the primary action while long press expands', (
    tester,
  ) async {
    var primaryActions = 0;
    await tester.pumpWidget(
      buildHarness(
        onBackgroundDrag: (_) {},
        onCollapsedTap: () => primaryActions += 1,
      ),
    );

    final hit = find.byKey(const ValueKey<String>('morph_hit'));
    await tester.tapAt(tester.getCenter(hit));
    await tester.pumpAndSettle();

    expect(primaryActions, 1);
    // The expanded content stays mounted but invisible while collapsed: its
    // glyph masks are pre-rasterized off the open animation's first frame.
    expect(find.text('Menu content'), findsOneWidget);
    expect(
      AdaptiveGlassEffects.of(
        tester.element(find.text('Menu content')),
      ).opacity,
      0,
    );

    await tester.longPress(hit);
    await tester.pumpAndSettle();

    expect(primaryActions, 1);
    expect(find.text('Menu content'), findsOneWidget);
  });

  testWidgets('menu content receives velocity blur during its spring morph', (
    tester,
  ) async {
    final controller = FolioSettingsController(
      store: MemorySettingsStore(const FolioSettings(blurEnabled: true)),
    );
    await controller.load();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      FolioSettingsScope(
        controller: controller,
        child: buildHarness(onBackgroundDrag: (_) {}),
      ),
    );
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey<String>('morph_hit'))),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 64));

    final effects = AdaptiveGlassEffects.of(
      tester.element(find.text('Menu content')),
    );
    expect(effects.blurSigma, greaterThan(0));
    expect(
      tester
          .widgetList<ImageFiltered>(find.byType(ImageFiltered))
          .any((filter) => filter.enabled),
      isTrue,
    );

    await tester.pumpAndSettle();
    expect(find.text('Menu content'), findsOneWidget);
  });
}
