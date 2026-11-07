import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/settings/widgets/folio_settings_sheet.dart';
import 'package:folio/shared/settings/folio_settings.dart';
import 'package:folio/shared/settings/folio_settings_controller.dart';
import 'package:folio/shared/settings/folio_settings_scope.dart';
import 'package:folio/shared/theme/folio_theme.dart';
import 'package:folio/shared/widgets/folio_bottom_sheet.dart';

import '../../support/memory_settings_store.dart';

const _openDuration = AppSprings.sheetOpenDuration;
const _closeDuration = AppSprings.sheetCloseDuration;

/// The exact entrance spring the route uses from a cold push.
final _entranceSimulation = SpringSimulation(
  AppSprings.sheetEntrance(_openDuration),
  0,
  1,
  0,
  tolerance: AppSprings.scaleTolerance,
);

final _sheet = find.byType(FolioSettingsSheet);
final _surface = find.byKey(const ValueKey<String>('folio_sheet_surface'));
final _backdrop = find.byKey(const ValueKey<String>('folio_sheet_backdrop'));
final _position = find.byKey(const ValueKey<String>('folio_sheet_position'));

void main() {
  testWidgets('settings use a floating surface with four 28px corners', (
    tester,
  ) async {
    await _pumpHost(tester);
    await _open(tester);
    await tester.pumpAndSettle();

    final rect = tester.getRect(_surface);
    expect(rect.left, 16);
    expect(rect.right, 384);
    // The spring settles within its tolerance of the rest point.
    expect(rect.bottom, closeTo(824, 0.5));
    // The Theme selector row makes the settings content reach the 85% height
    // cap; the body scrolls inside it from there.
    expect(rect.height, lessThanOrEqualTo(840 * 0.85));
    final decoration =
        tester.widget<DecoratedBox>(_surface).decoration as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(28));
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening rides the entrance spring with 700ms and 750px travel', (
    tester,
  ) async {
    await _pumpHost(tester, settings: const FolioSettings(blurEnabled: true));
    await _open(tester);
    final route = _route(tester);
    expect(route.transitionDuration, _openDuration);
    expect(_offset(tester), closeTo(750, 0.001));

    // The first checkpoint matches the entrance spring exactly; afterwards
    // the controller clamps its progress at 1 while the panel keeps reading
    // the unclipped spring (the overshoot bounce).
    await tester.pump(const Duration(milliseconds: 175));
    expect(
      _offset(tester),
      closeTo(750 * (1 - _entranceSimulation.x(0.175)), 0.5),
    );
    _expectBackdrop(tester, elapsedMs: 175);
    await tester.pump(const Duration(milliseconds: 175));
    expect(_offset(tester), lessThan(0));
    await tester.pumpAndSettle();
    expect(_offset(tester), closeTo(0, 0.5));
  });

  testWidgets('close rides the exit spring and the backdrop fades on its own', (
    tester,
  ) async {
    var completed = false;
    await _pumpHost(
      tester,
      settings: const FolioSettings(blurEnabled: true),
      onClosed: () => completed = true,
    );
    await _open(tester);
    await tester.pumpAndSettle();
    final route = _route(tester);
    expect(route.reverseTransitionDuration, _closeDuration);

    Navigator.of(tester.element(_sheet)).pop();
    await tester.pump();
    expect(completed, isFalse);
    await tester.pump(_closeDuration * 0.5);
    // The panel is on its way out but never jumps to the end.
    expect(_offset(tester), inExclusiveRange(0, 750));
    _expectBackdrop(tester, elapsedMs: 150, closing: true);
    expect(completed, isFalse);

    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
    expect(_backdrop, findsNothing);
    expect(completed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Blur disables both filters without remounting the sheet', (
    tester,
  ) async {
    final controller = await _pumpHost(
      tester,
      settings: const FolioSettings(blurEnabled: true),
    );
    await _open(tester);
    await tester.pumpAndSettle();
    final element = tester.element(_sheet);
    final rect = tester.getRect(_surface);

    await tester.tap(find.byKey(const ValueKey<String>('settings_blur')));
    await tester.pumpAndSettle();
    expect(controller.settings.blurEnabled, isFalse);
    expect(controller.settings.liquidMotionEnabled, isTrue);
    expect(
      tester
          .widgetList<BackdropFilter>(find.byType(BackdropFilter))
          .every((filter) => !filter.enabled),
      isTrue,
    );
    _expectBackdrop(
      tester,
      elapsedMs: _closeDuration.inMilliseconds,
      blurEnabled: controller.settings.blurEnabled,
    );
    expect(tester.element(_sheet), same(element));
    expect(tester.getRect(_surface), rect);
    expect(route_1(tester).animation!.value, closeTo(1, 0.001));

    await tester.tap(find.byKey(const ValueKey<String>('settings_blur')));
    await tester.pumpAndSettle();
    _expectBackdrop(
      tester,
      elapsedMs: _closeDuration.inMilliseconds,
      blurEnabled: controller.settings.blurEnabled,
    );
    expect(tester.element(_sheet), same(element));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Liquid motion does not disable or restart the sheet transition',
    (tester) async {
      final controller = await _pumpHost(
        tester,
        settings: const FolioSettings(
          blurEnabled: true,
          liquidMotionEnabled: false,
        ),
      );
      await _open(tester);
      final route = _route(tester);
      expect(route.transitionDuration, _openDuration);
      expect(route.reverseTransitionDuration, _closeDuration);
      // Opening runs on its own clock: after 175 ms the panel is near the
      // entrance overshoot, wherever the spring has put it.
      await tester.pump(const Duration(milliseconds: 175));
      final offset = _offset(tester);
      _expectBackdrop(tester, elapsedMs: 175);

      controller.setLiquidMotionEnabled(true);
      await tester.pump();
      expect(_offset(tester), closeTo(offset, 0.001));
      await tester.pumpAndSettle();
      expect(_offset(tester), closeTo(0, 0.5));
    },
  );

  testWidgets('closing during opening does not jump to the end position', (
    tester,
  ) async {
    await _pumpHost(tester);
    await _open(tester);
    await tester.pump(const Duration(milliseconds: 140));
    final offset = _offset(tester);
    Navigator.of(tester.element(_sheet)).pop();
    await tester.pump();
    expect(_offset(tester), closeTo(offset, 0.001));

    await tester.pump(const Duration(milliseconds: 35));
    // The exit spring inherits the entrance momentum, so the panel may
    // drift either way for a frame — it never teleports and stays on
    // screen until the dismissal settles.
    expect(
      _offset(tester),
      inExclusiveRange(-20, FolioBottomSheet.hiddenTravel),
    );
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  for (final size in <Size>[const Size(900, 1000), const Size(900, 480)]) {
    testWidgets(
      'stays a bottom sheet on a ${size.width}x${size.height} screen',
      (tester) async {
        await _pumpHost(tester, size: size);
        await _open(tester);
        await tester.pumpAndSettle();
        final rect = tester.getRect(_surface);
        // Wide screens get the compact panel docked bottom-right; the 400px
        // cap is the Folio sheet width on tablets and landscape phones.
        expect(rect.width, 400);
        expect(rect.right, size.width - 16);
        expect(rect.bottom, closeTo(size.height - 16, 0.5));
        expect(rect.height, lessThanOrEqualTo(size.height * 0.85));
        expect(find.byType(Dialog), findsNothing);
        expect(find.byType(DraggableScrollableSheet), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'large text remains scrollable above the keyboard and safe area',
    (tester) async {
      final controller = await _pumpHost(
        tester,
        size: const Size(280, 600),
        viewPadding: const EdgeInsets.only(top: 24, bottom: 24),
        viewInsets: const EdgeInsets.only(bottom: 220),
        textScaler: const TextScaler.linear(1.6),
      );
      await _open(tester);
      await tester.pumpAndSettle();
      final rect = tester.getRect(_surface);
      expect(rect.left, 16);
      expect(rect.right, 264);
      expect(rect.bottom, closeTo(600 - 220 - 16, 0.5));
      expect(rect.top, greaterThanOrEqualTo(24 + 16));

      final motion = find.byKey(
        const ValueKey<String>('settings_liquid_motion'),
      );
      await tester.ensureVisible(motion);
      await tester.pumpAndSettle();
      await tester.tap(motion);
      await tester.pumpAndSettle();
      expect(controller.settings.liquidMotionEnabled, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('safe area is outside the surface and is not counted twice', (
    tester,
  ) async {
    await _pumpHost(tester, viewPadding: const EdgeInsets.only(bottom: 24));
    await _open(tester);
    await tester.pumpAndSettle();
    expect(tester.getRect(_surface).bottom, closeTo(840 - 24 - 16, 0.5));
    expect(
      find.descendant(of: _surface, matching: find.byType(SafeArea)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the dismissible barrier and system Back close the sheet', (
    tester,
  ) async {
    await _pumpHost(tester);
    await _open(tester);
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(20, 40));
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);

    await _open(tester);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
    expect(find.text('Open settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ordinary downward swipe dismissal is retained', (tester) async {
    await _pumpHost(tester);
    await _open(tester);
    await tester.pumpAndSettle();
    final rect = tester.getRect(_surface);
    await tester.flingFrom(
      Offset(rect.center.dx, rect.top + 18),
      const Offset(0, 180),
      1000,
    );
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
    expect(_backdrop, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an upward drag does not expand the surface', (tester) async {
    await _pumpHost(tester);
    await _open(tester);
    await tester.pumpAndSettle();
    final rect = tester.getRect(_surface);
    await tester.dragFrom(
      Offset(rect.center.dx, rect.top + 18),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    final after = tester.getRect(_surface);
    expect(after.left, closeTo(rect.left, 0.5));
    expect(after.top, closeTo(rect.top, 0.5));
    expect(after.right, closeTo(rect.right, 0.5));
    expect(after.bottom, closeTo(rect.bottom, 0.5));
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a cancelled short drag returns without remounting content', (
    tester,
  ) async {
    await _pumpHost(tester);
    await _open(tester);
    await tester.pumpAndSettle();
    final rect = tester.getRect(_surface);
    final element = tester.element(_sheet);
    final gesture = await tester.startGesture(
      Offset(rect.center.dx, rect.top + 18),
    );
    await gesture.moveBy(const Offset(0, 28));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, 12));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();
    final after = tester.getRect(_surface);
    expect(after.left, closeTo(rect.left, 0.5));
    expect(after.top, closeTo(rect.top, 0.5));
    expect(after.right, closeTo(rect.right, 0.5));
    expect(after.bottom, closeTo(rect.bottom, 0.5));
    expect(tester.element(_sheet), same(element));
    expect(_offset(tester), closeTo(0, 0.5));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system reduced motion avoids tickers entirely', (tester) async {
    await _pumpHost(
      tester,
      settings: const FolioSettings(blurEnabled: true),
      disableAnimations: true,
    );
    await _open(tester);
    await tester.pumpAndSettle();
    expect(_route(tester).transitionDuration, Duration.zero);
    expect(_route(tester).reverseTransitionDuration, Duration.zero);
    expect(_offset(tester), 0);
    _expectBackdrop(tester, elapsedMs: _closeDuration.inMilliseconds);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing the app during opening disposes transition listeners', (
    tester,
  ) async {
    await _pumpHost(tester);
    await _open(tester);
    await tester.pump(const Duration(milliseconds: 90));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}

ModalRoute<dynamic> _route(WidgetTester tester) =>
    ModalRoute.of(tester.element(_sheet))!;

// Retained alias used by the blur-toggle test above.
ModalRoute<dynamic> route_1(WidgetTester tester) => _route(tester);

Future<FolioSettingsController> _pumpHost(
  WidgetTester tester, {
  Size size = const Size(400, 840),
  FolioSettings settings = const FolioSettings(),
  EdgeInsets viewPadding = EdgeInsets.zero,
  EdgeInsets viewInsets = EdgeInsets.zero,
  TextScaler textScaler = TextScaler.noScaling,
  bool disableAnimations = false,
  VoidCallback? onClosed,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final controller = FolioSettingsController(
    store: MemorySettingsStore(settings),
  );
  await controller.load();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  await tester.pumpWidget(
    FolioSettingsScope(
      controller: controller,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            viewPadding: viewPadding,
            padding: viewPadding,
            viewInsets: viewInsets,
            textScaler: textScaler,
            disableAnimations: disableAnimations,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  await showFolioSettingsSheet(context);
                  onClosed?.call();
                },
                child: const Text('Open settings'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('Open settings'));
  await tester.pump();
  expect(_sheet, findsOneWidget);
}

double _offset(WidgetTester tester) =>
    tester.widget<Transform>(_position).transform.storage[13];

/// The backdrop runs its own 300 ms wall-clock fade (neutral curve): the
/// helper mirrors that clock from the elapsed pump time instead of the
/// spring's route progress.
void _expectBackdrop(
  WidgetTester tester, {
  required int elapsedMs,
  bool blurEnabled = true,
  bool closing = false,
}) {
  final progress = (elapsedMs / _closeDuration.inMilliseconds).clamp(0.0, 1.0);
  final t = AppCurves.neutral.transform(closing ? 1.0 - progress : progress);
  final filter = tester.widget<BackdropFilter>(_backdrop);
  final blurActive = blurEnabled && t > 0;
  expect(filter.enabled, blurActive);
  final sigma = blurActive ? 8.0 * t : 8.0;
  expect(filter.filter, ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma));
  final color = tester.widget<ColoredBox>(
    find.descendant(of: _backdrop, matching: find.byType(ColoredBox)).first,
  );
  expect(color.color.a, closeTo((blurEnabled ? 0.3 : 0.6) * t, 0.005));
}
