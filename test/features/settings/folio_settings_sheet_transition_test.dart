import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/settings/widgets/folio_settings_sheet.dart';
import 'package:folio/shared/glass/surface/glass_panel.dart';
import 'package:folio/shared/settings/folio_settings.dart';
import 'package:folio/shared/settings/folio_settings_controller.dart';
import 'package:folio/shared/settings/folio_settings_scope.dart';

import '../../support/memory_settings_store.dart';

const _openingCurve = Cubic(0.24, 1.2, 0.2, 1.0);
final _sheet = find.byType(FolioSettingsSheet);
final _surface = find.byType(GlassPanel);
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
    expect(rect.bottom, 824);
    expect(rect.height, lessThan(840 * 0.85));
    expect(tester.widget<GlassPanel>(_surface).borderRadius, 28);
    final clip = find.descendant(
      of: _surface,
      matching: find.byType(ClipRRect),
    );
    expect(
      tester.widget<ClipRRect>(clip).borderRadius,
      BorderRadius.circular(28),
    );
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening uses the reference curve, 700ms and 750px travel', (
    tester,
  ) async {
    await _pumpHost(
      tester,
      settings: const FolioSettings(blurEnabled: true),
    );
    await _open(tester);
    final route = _route(tester);
    expect(route.transitionDuration, const Duration(milliseconds: 700));
    expect(_offset(tester), closeTo(750, 0.001));

    var elapsed = 0;
    for (final step in <int>[70, 105, 175, 175, 175]) {
      elapsed += step;
      await tester.pump(Duration(milliseconds: step));
      final raw = elapsed / 700;
      expect(route.animation!.value, closeTo(raw, 0.00001));
      expect(
        _offset(tester),
        closeTo(750 * (1 - _openingCurve.transform(raw)), 0.001),
      );
      _expectBackdrop(tester, raw);
    }
    expect(_offset(tester), closeTo(0, 0.001));
  });

  testWidgets('close keeps the reference motion and late backdrop fade', (
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
    expect(route.reverseTransitionDuration, const Duration(milliseconds: 350));

    Navigator.of(tester.element(_sheet)).pop();
    await tester.pump();
    expect(completed, isFalse);
    await tester.pump(const Duration(milliseconds: 175));
    expect(route.animation!.value, closeTo(0.5, 0.00001));
    expect(
      _offset(tester),
      closeTo(750 * (1 - Curves.easeInOutCubic.transform(0.5)), 0.001),
    );
    _expectBackdrop(
      tester,
      0.5,
    ); // Still fully blurred halfway through closing.
    expect(completed, isFalse);

    await tester.pump(const Duration(microseconds: 87500));
    expect(route.animation!.value, closeTo(0.25, 0.00001));
    expect(
      _offset(tester),
      closeTo(750 * (1 - Curves.easeInOutCubic.transform(0.25)), 0.001),
    );
    _expectBackdrop(tester, 0.25);
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
    final route = _route(tester);
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
    _expectBackdrop(tester, 1, blurEnabled: false);
    expect(tester.element(_sheet), same(element));
    expect(tester.getRect(_surface), rect);
    expect(route.animation!.value, 1);

    await tester.tap(find.byKey(const ValueKey<String>('settings_blur')));
    await tester.pumpAndSettle();
    _expectBackdrop(tester, 1);
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
      expect(route.transitionDuration, const Duration(milliseconds: 700));
      expect(
        route.reverseTransitionDuration,
        const Duration(milliseconds: 350),
      );
      await tester.pump(const Duration(milliseconds: 175));
      final offset = _offset(tester);
      _expectBackdrop(tester, 0.25);

      controller.setLiquidMotionEnabled(true);
      await tester.pump();
      expect(_offset(tester), closeTo(offset, 0.001));
      expect(route.animation!.value, closeTo(0.25, 0.00001));
      await tester.pumpAndSettle();
      expect(_offset(tester), closeTo(0, 0.001));
    },
  );

  testWidgets('closing during opening does not jump to the reverse curve', (
    tester,
  ) async {
    await _pumpHost(tester);
    await _open(tester);
    await tester.pump(const Duration(milliseconds: 140));
    final offset = _offset(tester);
    final route = _route(tester);
    Navigator.of(tester.element(_sheet)).pop();
    await tester.pump();
    expect(_offset(tester), closeTo(offset, 0.001));

    await tester.pump(const Duration(milliseconds: 35));
    expect(
      _offset(tester),
      closeTo(
        750 * (1 - _openingCurve.transform(route.animation!.value)),
        0.001,
      ),
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
        expect(rect.bottom, size.height - 16);
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
      expect(rect.bottom, 600 - 220 - 16);
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
    expect(tester.getRect(_surface).bottom, 840 - 24 - 16);
    expect(
      find.descendant(of: _surface, matching: find.byType(SafeArea)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the standard dismissible barrier and system Back close the sheet',
    (tester) async {
      await _pumpHost(tester);
      await _open(tester);
      await tester.pumpAndSettle();
      final barrier = find.descendant(
        of: _backdrop,
        matching: find.byType(ModalBarrier),
      );
      expect(tester.widget<ModalBarrier>(barrier).dismissible, isTrue);
      expect(tester.widget<ModalBarrier>(barrier).semanticsLabel, isNotEmpty);
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
    },
  );

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
    expect(tester.getRect(_surface), rect);
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
    expect(tester.getRect(_surface), rect);
    expect(tester.element(_sheet), same(element));
    expect(_offset(tester), closeTo(0, 0.001));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'system reduced motion avoids a zero-duration ratio and tickers',
    (tester) async {
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
      _expectBackdrop(tester, 1);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_sheet, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

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

ModalRoute<dynamic> _route(WidgetTester tester) =>
    ModalRoute.of(tester.element(_sheet))!;

double _offset(WidgetTester tester) =>
    tester.widget<Transform>(_position).transform.storage[13];

void _expectBackdrop(
  WidgetTester tester,
  double raw, {
  bool blurEnabled = true,
}) {
  final t = Curves.easeOut.transform((raw / 0.5).clamp(0.0, 1.0));
  final filter = tester.widget<BackdropFilter>(_backdrop);
  final blurActive = blurEnabled && t > 0;
  expect(filter.enabled, blurActive);
  // The route shares one of 20 quantized filters per animation step; the
  // expectation must use the same 0.6-sigma grid instead of the raw `12 * t`.
  final step = (t * 20).round().clamp(0, 20);
  final sigma = blurActive ? 12.0 * step / 20 : 12.0;
  expect(filter.filter, ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma));
  // Without backdrop blur the scrim is doubled so the sheet keeps its depth.
  expect(
    (filter.child! as ColoredBox).color.a,
    closeTo((blurEnabled ? 0.3 : 0.6) * t, 0.00001),
  );
}
