import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/reader/widgets/file_info_sheet.dart';
import 'package:folio/features/settings/widgets/folio_settings_sheet.dart';
import 'package:folio/shared/glass/surface/glass_panel.dart';
import 'package:folio/shared/glass/surface/glass_shell.dart';
import 'package:folio/shared/settings/folio_settings.dart';
import 'package:folio/shared/settings/folio_settings_controller.dart';
import 'package:folio/shared/settings/folio_settings_scope.dart';
import 'package:folio/shared/widgets/folio_sheet_content.dart';

import '../../support/memory_settings_store.dart';

enum _Sheet { settings, fileInfo }

const _openingCurve = Cubic(0.24, 1.2, 0.2, 1.0);
final _content = find.byType(FolioSheetContent);
final _surface = find.byType(GlassPanel);
final _backdrop = find.byKey(const ValueKey<String>('folio_sheet_backdrop'));
final _position = find.byKey(const ValueKey<String>('folio_sheet_position'));

// Run one presentation contract against BOTH public feature entry points.
void main() {
  for (final sheet in _Sheet.values) {
    group(sheet.name, () {
      testWidgets('uses the shared Settings surface and typography', (
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
        expect(tester.widget<GlassPanel>(_surface).borderRadius, 32);
        expect(tester.widget<GlassPanel>(_surface).liquidMotion, isTrue);
        expect(
          find.descendant(of: _surface, matching: find.byType(GlassShell)),
          findsOneWidget,
        );
        final rect = tester.getRect(_surface);
        expect(rect.left, 16);
        expect(rect.right, 384);
        expect(rect.bottom, 824);
        expect(rect.height, lessThanOrEqualTo(840 * 0.85));
        final scroll = tester.widget<SingleChildScrollView>(
          find.descendant(
            of: _content,
            matching: find.byType(SingleChildScrollView),
          ),
        );
        expect(scroll.padding, const EdgeInsets.fromLTRB(24, 12, 24, 24));
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

      testWidgets('shares opening, closing and backdrop animation', (
        tester,
      ) async {
        var completed = false;
        await _pumpHost(tester, sheet, onClosed: () => completed = true);
        await _open(tester);
        final route = ModalRoute.of(tester.element(_content))!;
        expect(route.transitionDuration, const Duration(milliseconds: 700));
        expect(
          route.reverseTransitionDuration,
          const Duration(milliseconds: 350),
        );
        expect(_offset(tester), closeTo(750, 0.001));
        for (var step = 1; step <= 4; step++) {
          await tester.pump(const Duration(milliseconds: 175));
          final raw = step / 4;
          expect(route.animation!.value, closeTo(raw, 0.00001));
          expect(
            _offset(tester),
            closeTo(750 * (1 - _openingCurve.transform(raw)), 0.001),
          );
          _expectBackdrop(tester, raw);
        }
        Navigator.of(tester.element(_content)).pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 175));
        expect(completed, isFalse);
        expect(
          _offset(tester),
          closeTo(750 * (1 - Curves.easeInOutCubic.transform(0.5)), 0.001),
        );
        _expectBackdrop(tester, 0.5);
        await tester.pump(const Duration(microseconds: 87500));
        _expectBackdrop(tester, 0.25);
        expect(completed, isFalse);
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
          expect(filters.every((filter) => filter.enabled == enabled), isTrue);
          expect(tester.element(_content), same(element));
          expect(tester.getRect(_surface), rect);
          _expectBackdrop(tester, 1, blurEnabled: enabled);
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
        expect(rect.bottom, 364);
        final lastValue = sheet == _Sheet.settings
            ? find.byKey(
                const ValueKey<String>('settings_show_navigation_on_scroll_up'),
              )
            : find.text('Sep 13, 2026');
        await tester.ensureVisible(lastValue);
        await tester.pumpAndSettle();
        expect(tester.getRect(lastValue).bottom, lessThanOrEqualTo(rect.bottom));
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
          expect(rect.bottom, size.height - 16);
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

      testWidgets('liquid shell responds without moving its inner cards', (
        tester,
      ) async {
        final settings = await _pumpHost(tester, sheet);
        await _open(tester);
        await tester.pumpAndSettle();
        final shell = find.descendant(
          of: _surface,
          matching: find.byType(GlassShell),
        );
        final card = find.byType(FolioSheetCard).first;
        final element = tester.element(card);
        final cardRect = tester.getRect(card);
        final rect = tester.getRect(_surface);
        final gesture = await tester.startGesture(
          Offset(rect.center.dx, rect.top + 16),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        // A horizontal pull exercises shell physics without dismissing vertically.
        await gesture.moveBy(const Offset(40, 0));
        await tester.pump(const Duration(milliseconds: 80));
        expect(tester.widget<GlassShell>(shell).press, greaterThan(0));
        expect(tester.getRect(card), cardRect);
        expect(tester.element(card), same(element));
        settings.setLiquidMotionEnabled(false);
        await tester.pumpAndSettle();
        expect(tester.widget<GlassShell>(shell).press, 0);
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
        _expectBackdrop(tester, 1);
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

void _expectBackdrop(
  WidgetTester tester,
  double raw, {
  bool blurEnabled = true,
}) {
  final t = Curves.easeOut.transform((raw / 0.5).clamp(0.0, 1.0));
  final filter = tester.widget<BackdropFilter>(_backdrop);
  expect(filter.enabled, blurEnabled && t > 0);
  expect(
    filter.filter,
    ui.ImageFilter.blur(
      sigmaX: blurEnabled && t > 0 && t < 1 ? 12 * t : 12,
      sigmaY: blurEnabled && t > 0 && t < 1 ? 12 * t : 12,
    ),
  );
  final color = tester.widget<ColoredBox>(
    find.descendant(of: _backdrop, matching: find.byType(ColoredBox)).first,
  );
  expect(color.color.a, closeTo((blurEnabled ? 0.3 : 0.6) * t, 0.005));
}
