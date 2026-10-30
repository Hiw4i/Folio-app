// Runs real OOXML -> Android WebView -> Flutter backdrop composition.
// A Flutter-painted substitute cannot validate this regression.
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/reader/logic/reader_state.dart';
import 'package:folio/features/reader/office/data/office_document_gateway.dart';
import 'package:folio/features/reader/office/logic/office_document_renderer_base.dart';
import 'package:folio/features/reader/office/widgets/office_document_platform_view.dart';
import 'package:folio/features/reader/office/widgets/office_selection_magnifier.dart';
import 'package:folio/features/reader/office/widgets/office_selection_overlay.dart';
import 'package:folio/features/reader/powerpoint/logic/powerpoint_document_renderer.dart';
import 'package:folio/features/reader/word/logic/word_document_renderer.dart';
import 'package:folio/shared/glass/liquid_glass.dart';
import 'package:folio/shared/settings/folio_settings.dart';
import 'package:folio/shared/settings/folio_settings_controller.dart';
import 'package:folio/shared/settings/folio_settings_scope.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../test/support/memory_settings_store.dart';
import 'fixtures/office_contrast.dart';

const _capture = ValueKey('office_glass_capture');
const _leftInk = ValueKey('office_left_ink');
const _rightInk = ValueKey('office_right_ink');

Widget _scene(
  OfficeDocumentRendererBase renderer,
  FolioSettingsController settings, {
  required bool controls,
}) => FolioSettingsScope(
  controller: settings,
  child: Builder(
    builder: (context) => MediaQuery.fromView(
      view: View.of(context),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: _capture,
          child: ColoredBox(
            color: const Color(0xFF00FF00),
            child: LayoutBuilder(
              builder: (context, constraints) => Stack(
                fit: StackFit.expand,
                children: [
                  OfficeDocumentPlatformView(
                    renderer: renderer,
                    onContentTap: () {},
                  ),
                  if (controls) ...[
                    for (final left in [true, false])
                      Positioned(
                        left: left ? 24 : null,
                        right: left ? null : 24,
                        top: renderer.document.format == DocumentFormat.pptx
                            ? 310
                            : 110,
                        child: LiquidGlassControl(
                          size: const Size(100, 48),
                          child: AdaptiveGlassText(
                            'MM',
                            key: left ? _leftInk : _rightInk,
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 24,
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                    LiquidMorphingControl(
                      geometryBuilder: (_) => LiquidMorphGeometry(
                        collapsedRect: Rect.fromLTWH(
                          constraints.maxWidth - 72,
                          24,
                          48,
                          48,
                        ),
                        expandedRect: Rect.fromLTWH(
                          constraints.maxWidth - 260,
                          24,
                          236,
                          160,
                        ),
                      ),
                      collapsedSemanticsLabel: 'Office test menu',
                      collapsedChild: const Center(
                        child: AdaptiveGlassIcon(LucideIcons.moreVertical),
                      ),
                      expandedChild: const Center(
                        child: AdaptiveGlassText(
                          'File info',
                          style: TextStyle(fontFamily: 'Inter', fontSize: 20),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

class _Pixels {
  _Pixels(this.data, this.width, this.ratio);
  final ByteData data;
  final int width;
  final double ratio;

  List<int> channel(Rect rect, int channel) => [
    for (
      var y = (rect.top * ratio).ceil();
      y < (rect.bottom * ratio).floor();
      y++
    )
      for (
        var x = (rect.left * ratio).ceil();
        x < (rect.right * ratio).floor();
        x++
      )
        data.getUint8((y * width + x) * 4 + channel),
  ];

  double mean(Rect rect, int component) {
    final values = channel(rect, component);
    return values.reduce((a, b) => a + b) / values.length;
  }

  double variance(Rect rect) {
    final values = channel(rect, 0);
    final average = values.reduce((a, b) => a + b) / values.length;
    return values.fold<double>(
          0,
          (sum, v) => sum + (v - average) * (v - average),
        ) /
        values.length;
  }
}

Future<_Pixels> _pixels(WidgetTester tester, [String? label]) async {
  final ratio = tester.view.devicePixelRatio;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_capture),
  );
  final image = await boundary.toImage(pixelRatio: ratio);
  try {
    if (label != null) {
      final directory = Directory('${Directory.systemTemp.path}/office-glass');
      await directory.create(recursive: true);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File('${directory.path}/$label.png')
          .writeAsBytes(png.buffer.asUint8List());
      debugPrint('OFFICE_CAPTURE_FILE ${directory.path}/$label.png');
    }
    return _Pixels(
      (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!,
      image.width,
      ratio,
    );
  } finally {
    image.dispose();
  }
}

void _expectInk(WidgetTester tester, _Pixels pixels, bool left) {
  final rect = tester
      .getRect(find.byKey(left ? _leftInk : _rightInk))
      .deflate(2);
  for (final half in [
    Rect.fromLTRB(rect.left, rect.top, rect.right, rect.center.dy),
    Rect.fromLTRB(rect.left, rect.center.dy, rect.right, rect.bottom),
  ]) {
    final ink = pixels.channel(half, 0);
    expect(
      ink.where((v) => left ? v > 220 : v < 50).length,
      greaterThan(15),
      reason:
          '${left ? 'White' : 'Black'} ink must occupy BOTH halves of the glyph over Office.',
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final format in [DocumentFormat.docx, DocumentFormat.pptx]) {
    testWidgets(
      '${format.extension}: real WebView supplies blur and per-object color through menu open/close',
      (tester) async {
        expect(ui.ImageFilter.isShaderFilterSupported, isTrue);
        final temporary = await Directory.systemTemp.createTemp(
          'office_glass_',
        );
        final file = File('${temporary.path}/contrast.${format.extension}');
        await file.writeAsBytes(
          base64Decode(
            format == DocumentFormat.docx
                ? docxContrastBase64
                : pptxContrastBase64,
          ),
        );
        final document = DocumentEntry(
          id: file.path,
          source: FileDocumentSource(file.path),
          name: 'contrast.${format.extension}',
          format: format,
          sizeBytes: await file.length(),
          modifiedAt: DateTime.utc(2026, 10, 30),
        );
        final OfficeDocumentRendererBase renderer =
            format == DocumentFormat.docx
            ? WordDocumentRenderer(
                document: document,
                gateway: const DeviceOfficeDocumentGateway(),
              )
            : PowerPointDocumentRenderer(
                document: document,
                gateway: const DeviceOfficeDocumentGateway(),
              );
        final settings = FolioSettingsController(
          store: MemorySettingsStore(const FolioSettings(blurEnabled: true)),
        );
        await settings.load();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await renderer.close();
          renderer.dispose();
          settings.dispose();
          await temporary.delete(recursive: true);
        });
        await precacheAdaptiveGlassForeground();
        await renderer.open();
        await tester.pumpWidget(_scene(renderer, settings, controls: false));
        for (
          var i = 0;
          i < 300 && renderer.loadState == ReaderLoadState.loading;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(
          renderer.loadState,
          ReaderLoadState.ready,
          reason: renderer.failure?.message,
        );
        await tester.pump(const Duration(milliseconds: 500));
        final surface = tester.widget<AndroidViewSurface>(
          find.byType(AndroidViewSurface),
        );
        debugPrint(
          'OFFICE_COMPOSITION ${format.extension} hybrid=${surface.controller.requiresViewComposition} texture=${surface.controller.textureId}',
        );
        expect(
          surface.controller.requiresViewComposition,
          isFalse,
          reason: 'Office must not silently fall back to separate native overlay surfaces.',
        );
        final background = await _pixels(tester, '${format.extension}_body');
        final size = tester.getSize(find.byKey(_capture));
        final controlsTop = format == DocumentFormat.pptx ? 310.0 : 110.0;
        expect(
          background.mean(Rect.fromLTWH(40, controlsTop + 70, 40, 30), 0),
          lessThan(70),
          reason:
              'DOCX/PPTX must be present in Flutter\'s actual backdrop input.',
        );
        expect(
          background.mean(
            Rect.fromLTWH(size.width - 90, controlsTop + 70, 40, 30),
            1,
          ),
          greaterThan(170),
        );
        await tester.pumpWidget(_scene(renderer, settings, controls: true));
        await tester.pumpAndSettle();
        final painted = await _pixels(tester, '${format.extension}_controls');
        _expectInk(tester, painted, true);
        _expectInk(tester, painted, false);
        if (const bool.fromEnvironment('FOLIO_OFFICE_CAPTURE_SCREEN')) {
          debugPrint('OFFICE_SCREEN_READY ${format.extension}');
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(seconds: 20)),
          );
        }
        final band = Rect.fromLTWH(size.width - 110, controlsTop + 6, 70, 7);
        expect(
          painted.variance(band),
          lessThan(background.variance(band) * .5),
          reason:
              'Glass must actually soften the stripes in the native document.',
        );
        final menu = tester.state<LiquidMorphingControlState>(
          find.byType(LiquidMorphingControl),
        );
        for (var repeat = 0; repeat < 2; repeat++) {
          menu.open();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          _expectInk(tester, await _pixels(tester), true);
          await tester.pumpAndSettle();
          menu.close();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          _expectInk(tester, await _pixels(tester), true);
          await tester.pumpAndSettle();
          final closed = await _pixels(tester);
          _expectInk(tester, closed, true);
          _expectInk(tester, closed, false);
        }
        // Exercise the existing native selection API against the real OOXML DOM.
        final channel = MethodChannel(
          'folio/office_view/${surface.controller.viewId}',
        );
        await channel.invokeMethod<void>('selectAll');
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(OfficeSelectionOverlay), findsOneWidget);

        // Inject at the platform-message boundary, where the real DOM's owned
        // handle events arrive. The lens must magnify the actual WebView texture.
        Future<void> handle(bool active) async {
          final done = Completer<void>();
          tester.binding.channelBuffers.push(
                channel.name,
                const StandardMethodCodec().encodeMethodCall(
                  MethodCall('event', {
                    'type': 'selectionHandle',
                    'active': active,
                    'x': .85,
                    'y': (controlsTop + 80) / size.height,
                  }),
                ),
                (_) => done.complete(),
              );
          await done.future;
          await tester.pump();
        }

        await handle(true);
        expect(find.byType(OfficeSelectionMagnifier), findsOneWidget);
        final lens = tester.getRect(find.byType(RawMagnifier)).deflate(6);
        expect(
          (await _pixels(tester)).mean(lens, 1),
          greaterThan(100),
          reason: 'The loupe must contain Office pixels rather than a black native capture.',
        );
        await handle(false);
        expect(find.byType(OfficeSelectionMagnifier), findsNothing);
        await handle(true);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        expect(find.byType(OfficeSelectionMagnifier), findsNothing);
        await handle(true);
        expect(find.byType(OfficeSelectionMagnifier), findsNothing);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await handle(false);
        await tester.tap(
          find.byKey(const ValueKey<String>('folio_toolbar_copy')),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          (await Clipboard.getData(Clipboard.kTextPlain))?.text,
          contains('Office selection regression text'),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
