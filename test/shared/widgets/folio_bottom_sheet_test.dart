import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/reader/widgets/file_info_sheet.dart';
import 'package:folio/features/settings/widgets/folio_settings_sheet.dart';
import 'package:folio/shared/settings/folio_settings.dart';
import 'package:folio/shared/settings/folio_settings_controller.dart';
import 'package:folio/shared/settings/folio_settings_scope.dart';
import 'package:folio/shared/theme/folio_theme.dart';
import 'package:folio/shared/widgets/folio_sheet_content.dart';

import '../../support/memory_settings_store.dart';

enum _Sheet { settings, fileInfo }

const _openDuration = AppSprings.sheetOpenDuration;
const _closeDuration = AppSprings.sheetCloseDuration;

final _content = find.byType(FolioSheetContent);
final _surface = find.byKey(const ValueKey<String>('folio_sheet_surface'));
final _backdrop = find.byKey(const ValueKey<String>('folio_sheet_backdrop'));
final _position = find.byKey(const ValueKey<String>('folio_sheet_position'));

/// The exact entrance spring the route uses from a cold push.
final _entranceSimulation = SpringSimulation(
  AppSprings.sheetEntrance(_openDuration),
  0,
  1,
  0,
  tolerance: AppSprings.scaleTolerance,
);

// Run one presentation contract against BOTH public feature entry points.
void main() {
  for (final sheet in _Sheet.values) {
    group(sheet.name, () {
      testWidgets('uses the shared opaque Settings surface and typography', (
        tester,
      ) async {
        await _pumpHost(tester, sheet);
        await _open(tester);
        await tester.pumpAndSettle();

        expect(_content, findsOneWidget);
        expect(_surface, findsOneWidget);
        expect(find.byType(FolioSheetSectionHeader), findsWidgets);
        expect(find.byType(FolioSheetCard), findsWidgets);
        expect(find.byType(FolioSheetDivider), findsWidgets);
        final decoration =
            tester.widget<DecoratedBox>(_surface).decoration as BoxDecoration;
        expect(decoration.borderRadius, BorderRadius.circular(28));
        // The shared sheet is always opaque so content stays readable over
        // any backdrop, and the cards themselves never deform.
        expect(decoration.color, darkGlassColors.opaqueFill);
        expect(decoration.border, isNotNull);
        final rect = tester.getRect(_surface);
        expect(rect.left, 16);
        expect(rect.right, 384);
        // The spring settles within its tolerance, so the resting bottom can
        // be a fraction of a pixel off the exact position.
        expect(rect.bottom, closeTo(824, 0.5));
        expect(rect.height, lessThanOrEqualTo(840 * 0.85));
        final scroll = tester.widget<SingleChildScrollView>(
          find.descendant(
            of: _content,
            matching: find.byType(SingleChildScrollView),
          ),
        );
        expect(scroll.padding, AppSpacing.sheetPadding);
        final title = tester.widget<Text>(
          find.text(sheet == _Sheet.settings ? 'SETTINGS' : 'FILE INFO'),
        );
        expect(title.style?.fontSize, 24);
        expect(title.style?.fontWeight, FontWeight.w600);
        expect(title.style?.decoration, TextDecoration.none);
        expect(title.textAlign, TextAlign.center);
        expect(find.byType(Dialog), findsNothing);
        expect(find.byType(DraggableScrollableSheet), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('rides the entrance spring and closes on the exit spring', (
        tester,
      ) async {
        var completed = false;
        await _pumpHost(tester, sheet, onClosed: () => completed = true);
        await _open(tester);
        final route = ModalRoute.of(tester.element(_content))!;
        expect(route.transitionDuration, _openDuration);
        expect(route.reverseTransitionDuration, _closeDuration);
        expect(_offset(tester), closeTo(750, 0.001));

        // The route controller runs the entrance spring; its own progress is
        // clamped to [0, 1], but the panel reads the UNCLIPPED spring through
        // the visual channel — that overshoot past the rest point is the
        // whole point of the bounce.
        // The first checkpoint matches the entrance spring exactly; the
        // controller then clamps its own progress at 1 while the panel keeps
        // reading the unclipped spring, so mid-overshoot only the SIGN of
        // the bounce is asserted. The sheet finally settles on the rest
        // point (within the spring tolerance).
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

        Navigator.of(tester.element(_content)).pop();
        await tester.pump();
        await tester.pump(_closeDuration * 0.5);
        expect(completed, isFalse);
        // The panel is on its way out but never jumps.
        expect(_offset(tester), inExclusiveRange(0, 750));
        _expectBackdrop(tester, elapsedMs: 150, closing: true);
        await tester.pumpAndSettle();
        expect(completed, isTrue);
        expect(_content, findsNothing);
        expect(_backdrop, findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('live Blur changes do not remount the content', (
        tester,
      ) async {
        final controller = await _pumpHost(tester, sheet);
        await _open(tester);
        await tester.pumpAndSettle();
        final element = tester.element(_content);
        final rect = tester.getRect(_surface);
        for (final enabled in <bool>[false, true, false]) {
          controller.setBlurEnabled(enabled);
          await tester.pumpAndSettle();
          final filters = tester.widgetList<BackdropFilter>(
            find.byType(BackdropFilter),
          );
          expect(filters, isNotEmpty);
          // The route backdrop blurs; the opaque sheet surface carries no
          // filter at all.
          expect(filters.any((filter) => filter.enabled == enabled), isTrue);
          expect(tester.element(_content), same(element));
          expect(tester.getRect(_surface), rect);
          _expectBackdrop(
            tester,
            elapsedMs: _closeDuration.inMilliseconds,
            blurEnabled: enabled,
          );
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('large text scrolls above the keyboard and safe area', (
        tester,
      ) async {
        await _pumpHost(
          tester,
          sheet,
          size: const Size(280, 600),
          viewPadding: const EdgeInsets.only(top: 24, bottom: 24),
          viewInsets: const EdgeInsets.only(bottom: 220),
          textScaler: const TextScaler.linear(1.8),
          longName: true,
        );
        await _open(tester);
        await tester.pumpAndSettle();
        final rect = tester.getRect(_surface);
        expect(rect.left, 16);
        expect(rect.right, 264);
        expect(rect.top, greaterThanOrEqualTo(40));
        expect(rect.bottom, closeTo(364, 0.5));
        final lastValue = sheet == _Sheet.settings
            ? find.byKey(
                const ValueKey<String>('settings_show_navigation_on_scroll_up'),
              )
            : find.text('Sep 13, 2026');
        await tester.ensureVisible(lastValue);
        await tester.pumpAndSettle();
        expect(
          tester.getRect(lastValue).bottom,
          lessThanOrEqualTo(rect.bottom),
        );
        expect(tester.takeException(), isNull);
      });

      for (final size in <Size>[const Size(900, 1000), const Size(900, 480)]) {
        testWidgets('docks bottom-right as a compact sheet at $size', (
          tester,
        ) async {
          await _pumpHost(tester, sheet, size: size);
          await _open(tester);
          await tester.pumpAndSettle();
          final rect = tester.getRect(_surface);
          expect(rect.width, 400);
          expect(rect.right, size.width - 16);
          expect(rect.bottom, closeTo(size.height - 16, 0.5));
          expect(rect.height, lessThanOrEqualTo(size.height * 0.85));
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets('dismisses by outside tap, Back and downward swipe', (
        tester,
      ) async {
        await _pumpHost(tester, sheet);
        for (var method = 0; method < 3; method++) {
          await _open(tester);
          await tester.pumpAndSettle();
          if (method == 0) {
            await tester.tapAt(const Offset(20, 40));
          } else if (method == 1) {
            await tester.binding.handlePopRoute();
          } else {
            final rect = tester.getRect(_surface);
            await tester.flingFrom(
              Offset(rect.center.dx, rect.top + 18),
              const Offset(0, 180),
              1000,
            );
          }
          await tester.pumpAndSettle();
          expect(_content, findsNothing);
          expect(_backdrop, findsNothing);
          expect(find.text('Open sheet'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      });

      testWidgets('static surface keeps its cards fixed and still dismisses', (
        tester,
      ) async {
        final settings = await _pumpHost(tester, sheet);
        await _open(tester);
        await tester.pumpAndSettle();
        final card = find.byType(FolioSheetCard).first;
        final element = tester.element(card);
        final cardRect = tester.getRect(card);
        final rect = tester.getRect(_surface);
        final gesture = await tester.startGesture(
          Offset(rect.center.dx, rect.top + 16),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        // A horizontal pull exercises the press path without dismissing.
        await gesture.moveBy(const Offset(40, 0));
        await tester.pump(const Duration(milliseconds: 80));
        expect(tester.getRect(card), cardRect);
        expect(tester.element(card), same(element));
        settings.setLiquidMotionEnabled(false);
        await tester.pumpAndSettle();
        expect(tester.element(card), same(element));
        await gesture.up();
        await tester.pumpAndSettle();
        // Turning physics off must not turn off normal drag-to-dismiss.
        await tester.flingFrom(
          Offset(rect.center.dx, rect.top + 16),
          const Offset(0, 180),
          1000,
        );
        await tester.pumpAndSettle();
        expect(_content, findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('system reduced motion leaves no transition tickers', (
        tester,
      ) async {
        await _pumpHost(tester, sheet, disableAnimations: true);
        await _open(tester);
        await tester.pumpAndSettle();
        final route = ModalRoute.of(tester.element(_content))!;
        expect(route.transitionDuration, Duration.zero);
        expect(route.reverseTransitionDuration, Duration.zero);
        expect(_offset(tester), 0);
        _expectBackdrop(tester, elapsedMs: _closeDuration.inMilliseconds);
        expect(tester.binding.transientCallbackCount, 0);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(_content, findsNothing);
        expect(tester.takeException(), isNull);
      });
    });
  }
}

Future<FolioSettingsController> _pumpHost(
  WidgetTester tester,
  _Sheet sheet, {
  Size size = const Size(400, 840),
  EdgeInsets viewPadding = EdgeInsets.zero,
  EdgeInsets viewInsets = EdgeInsets.zero,
  TextScaler textScaler = TextScaler.noScaling,
  bool disableAnimations = false,
  bool longName = false,
  VoidCallback? onClosed,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final controller = FolioSettingsController(
    store: MemorySettingsStore(const FolioSettings(blurEnabled: true)),
  );
  await controller.load();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  final document = DocumentEntry(
    id: 'info-test',
    source: const FileDocumentSource('/documents/notes.txt'),
    name: longName
        ? '${List<String>.filled(12, 'Long_filename_').join()}.txt'
        : 'Notes.txt',
    format: DocumentFormat.txt,
    sizeBytes: 120,
    createdAt: DateTime(2026, 9, 10),
    modifiedAt: DateTime(2026, 9, 13),
  );
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
                  if (sheet == _Sheet.settings) {
                    await showFolioSettingsSheet(context);
                  } else {
                    await showFolioFileInfoSheet(context, document: document);
                  }
                  onClosed?.call();
                },
                child: const Text('Open sheet'),
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
  await tester.tap(find.text('Open sheet'));
  await tester.pump();
  expect(_content, findsOneWidget);
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
