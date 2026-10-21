import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/reader/data/document_content_source.dart';
import 'package:folio/features/reader/logic/document_renderer.dart';
import 'package:folio/features/reader/logic/reader_state.dart';
import 'package:folio/features/reader/office/data/office_document_gateway.dart';
import 'package:folio/features/reader/pdf/widgets/pdf_document_view.dart';
import 'package:folio/features/reader/powerpoint/widgets/powerpoint_document_view.dart';
import 'package:folio/features/reader/text/data/text_document.dart';
import 'package:folio/features/reader/text/widgets/text_document_view.dart';
import 'package:folio/features/reader/widgets/reader_chrome.dart';
import 'package:folio/features/reader/widgets/reader_screen.dart';
import 'package:folio/features/reader/word/widgets/word_document_view.dart';
import 'package:folio/shared/glass/widgets/liquid_search_control.dart';
import 'package:folio/shared/settings/folio_settings.dart';
import 'package:folio/shared/settings/folio_settings_controller.dart';
import 'package:folio/shared/settings/folio_settings_scope.dart';

import '../../support/memory_settings_store.dart';

// Reader-side contract tests. PDF and Office use classified callbacks, not
// native engines/WebViews; these tests do not validate native recognition.
void main() {
  for (final format in DocumentFormat.values) {
    testWidgets('${format.name}: content taps hide and show every panel', (
      tester,
    ) async {
      await _pumpReader(tester, format);
      _expectChrome(tester, true);
      await _tapContent(tester, format);
      await tester.pumpAndSettle();
      _expectChrome(tester, false);
      await _tapContent(tester, format);
      await tester.pumpAndSettle();
      _expectChrome(tester, true);
    });

    testWidgets('${format.name}: expanded search blocks chrome toggling', (
      tester,
    ) async {
      await _pumpReader(tester, format);
      tester.state<LiquidSearchControlState>(
        find.byType(LiquidSearchControl),
      ).open();
      await tester.pumpAndSettle();
      await _tapContent(tester, format);
      await tester.pumpAndSettle();
      _expectChrome(tester, true);
    });

    if (format == DocumentFormat.pptx) continue;
    testWidgets('${format.name}: scroll-driven navigation obeys live settings', (
      tester,
    ) async {
      final settings = await _pumpReader(tester, format, showOnScrollUp: false);
      await _tapContent(tester, format);
      await tester.pumpAndSettle();
      _readingScroll(tester, format, -100);
      await tester.pumpAndSettle();
      _expectChrome(tester, false); // Disabled: scroll up does not reveal.
      await _tapContent(tester, format);
      await tester.pumpAndSettle();
      _expectChrome(tester, true); // Manual reveal always remains available.
      _readingScroll(tester, format, 100);
      await tester.pumpAndSettle();
      _expectChrome(tester, true); // Disabled: scroll down does not hide.

      settings.setShowNavigationOnScrollUp(true);
      await tester.pumpAndSettle();
      _expectChrome(tester, true); // Changing the setting is not a hide.
      _readingScroll(tester, format, 100);
      await tester.pumpAndSettle();
      _expectChrome(tester, false); // Enabled: downward auto-hide works.
      _readingScroll(tester, format, -100);
      await tester.pumpAndSettle();
      _expectChrome(tester, true); // Enabled: upward reveal works.

      settings.setShowNavigationOnScrollUp(false);
      await tester.pumpAndSettle();
      _readingScroll(tester, format, 100);
      await tester.pumpAndSettle();
      _expectChrome(tester, true); // Disabled again: scroll is ignored.
      await _tapContent(tester, format);
      await tester.pumpAndSettle();
      _expectChrome(tester, false); // Manual hide always remains available.
      _readingScroll(tester, format, -100);
      await tester.pumpAndSettle();
      _expectChrome(tester, false); // Disabled: scroll up does not reveal.
      await _tapContent(tester, format);
      await tester.pumpAndSettle();
      _expectChrome(tester, true); // Manual reveal always remains available.
    });
  }

  testWidgets('a second content tap reverses an in-flight hide animation', (
    tester,
  ) async {
    await _pumpReader(tester, DocumentFormat.pdf);
    await _tapContent(tester, DocumentFormat.pdf);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final shell = tester.widget<ReaderChromeShell>(find.byType(ReaderChromeShell).first);
    expect(shell.progress.value, allOf(greaterThan(0), lessThan(1)));
    await _tapContent(tester, DocumentFormat.pdf);
    await tester.pumpAndSettle();
    _expectChrome(tester, true);
  });

  testWidgets('native scroll threshold is reset after a manual toggle', (
    tester,
  ) async {
    await _pumpReader(tester, DocumentFormat.docx);
    _readingScroll(tester, DocumentFormat.docx, 8);
    await _tapContent(tester, DocumentFormat.docx);
    await tester.pumpAndSettle();
    _expectChrome(tester, false);
    _readingScroll(tester, DocumentFormat.docx, -8);
    await tester.pumpAndSettle();
    _expectChrome(tester, false);
    _readingScroll(tester, DocumentFormat.docx, -8);
    await tester.pumpAndSettle();
    _expectChrome(tester, true);
  });

  testWidgets('ballistic, horizontal and nested text scrolling cannot toggle panels', (
    tester,
  ) async {
    await _pumpReader(tester, DocumentFormat.txt);
    await _tapContent(tester, DocumentFormat.txt);
    await tester.pumpAndSettle();
    _dispatchTextScroll(tester, -100, dragged: false);
    _dispatchTextScroll(tester, -100, direction: AxisDirection.right);
    final context = _textContext(tester);
    _NestedScrollNotification(context).dispatch(context);
    await tester.pumpAndSettle();
    _expectChrome(tester, false);
  });

  testWidgets('partial text scroll intents do not leak across separate drags', (
    tester,
  ) async {
    await _pumpReader(tester, DocumentFormat.txt);
    await _tapContent(tester, DocumentFormat.txt);
    await tester.pumpAndSettle();
    _dispatchTextScroll(tester, -8);
    final context = _textContext(tester);
    ScrollEndNotification(metrics: _metrics(), context: context).dispatch(context);
    _dispatchTextScroll(tester, -8);
    await tester.pumpAndSettle();
    _expectChrome(tester, false);
    _dispatchTextScroll(tester, -8);
    await tester.pumpAndSettle();
    _expectChrome(tester, true);
  });

  testWidgets('selection, long presses, cancelled and secondary taps keep panels stable', (
    tester,
  ) async {
    await _pumpReader(tester, DocumentFormat.txt);
    final view = tester.widget<TextDocumentView>(find.byType(TextDocumentView));
    view.onSelectionChanged!(true);
    await _tapContent(tester, DocumentFormat.txt);
    _dispatchTextScroll(tester, 100);
    await tester.pumpAndSettle();
    _expectChrome(tester, true);
    view.onSelectionChanged!(false);

    final held = await tester.startGesture(const Offset(400, 420));
    await tester.pump(const Duration(milliseconds: 550));
    await held.up();
    await tester.pumpAndSettle();
    _expectChrome(tester, true);

    final cancelled = await tester.startGesture(const Offset(400, 420));
    await cancelled.cancel();
    await tester.pumpAndSettle();
    _expectChrome(tester, true);

    final secondary = await tester.startGesture(
      const Offset(400, 420),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await secondary.up();
    await tester.pumpAndSettle();
    _expectChrome(tester, true);
  });

  testWidgets('hidden panels survive rotation and effect changes', (tester) async {
    final settings = await _pumpReader(tester, DocumentFormat.docx);
    await _tapContent(tester, DocumentFormat.docx);
    await tester.pumpAndSettle();
    settings.setBlurEnabled(false);
    settings.setLiquidMotionEnabled(false);
    await tester.binding.setSurfaceSize(const Size(915, 412));
    await tester.pumpAndSettle();
    _expectChrome(tester, false);
    await _tapContent(tester, DocumentFormat.docx);
    await tester.pumpAndSettle();
    _expectChrome(tester, true);
  });

  testWidgets('PPTX remains centre-tap-only with either scroll preference', (
    tester,
  ) async {
    final settings = await _pumpReader(tester, DocumentFormat.pptx);
    for (final enabled in <bool>[true, false]) {
      settings.setShowNavigationOnScrollUp(enabled);
      await tester.pumpAndSettle();
      await _tapContent(tester, DocumentFormat.pptx);
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(PowerPointDocumentView));
      ScrollUpdateNotification(
        metrics: _metrics(),
        context: context,
        scrollDelta: -100,
        dragDetails: DragUpdateDetails(globalPosition: const Offset(200, 400)),
      ).dispatch(context);
      await tester.pumpAndSettle();
      _expectChrome(tester, false);
      await _tapContent(tester, DocumentFormat.pptx);
      await tester.pumpAndSettle();
      _expectChrome(tester, true);
    }
  });
}

Future<FolioSettingsController> _pumpReader(
  WidgetTester tester,
  DocumentFormat format, {
  bool showOnScrollUp = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(412, 915));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final settings = FolioSettingsController(
    store: MemorySettingsStore(FolioSettings(showNavigationOnScrollUp: showOnScrollUp)),
  );
  await settings.load();
  addTearDown(settings.dispose);
  final path = '/reader.${format.extension}';
  final document = DocumentEntry(
    id: path,
    source: FileDocumentSource(path),
    name: 'Reader.${format.extension}',
    format: format,
    sizeBytes: 100,
    modifiedAt: DateTime.utc(2026, 9, 19),
  );
  final source = MemoryDocumentContentSource(<String, Uint8List>{});
  final DocumentRenderer renderer;
  switch (format) {
    case DocumentFormat.pdf:
      renderer = _PdfStub(document: document, contentSource: source);
    case DocumentFormat.docx:
      final word = WordDocumentRenderer(document: document, gateway: _OfficeGateway());
      await word.open();
      word.handleViewEvent(<Object?, Object?>{'type': 'ready', 'count': 3, 'hasText': true});
      renderer = word;
    case DocumentFormat.pptx:
      final slides = PowerPointDocumentRenderer(document: document, gateway: _OfficeGateway());
      await slides.open();
      slides.handleViewEvent(<Object?, Object?>{'type': 'ready', 'count': 3, 'hasText': true});
      renderer = slides;
    case DocumentFormat.txt || DocumentFormat.markdown:
      final text = List<String>.generate(60, (i) => 'Reading paragraph $i.').join('\n\n');
      renderer = TextDocumentRenderer(document: document, loader: TextDocumentLoader(source))
        ..content = TextDocument(
          text: text,
          chunks: <TextDocumentChunk>[TextDocumentChunk(startOffset: 0, text: text)],
          encoding: TextDocumentEncoding.utf8,
          isMarkdown: format == DocumentFormat.markdown,
        )
        ..loadState = ReaderLoadState.ready;
  }
  await tester.pumpWidget(FolioSettingsScope(
    controller: settings,
    child: MaterialApp(home: ReaderScreen(
      document: document,
      contentSource: source,
      initialRenderer: renderer,
      onRemoveFromRecents: () async {},
    )),
  ));
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await settings.flush();
  });
  return settings;
}

Future<void> _tapContent(WidgetTester tester, DocumentFormat format) async {
  switch (format) {
    case DocumentFormat.pdf:
      tester.widget<PdfDocumentView>(find.byType(PdfDocumentView)).onContentTap();
    case DocumentFormat.docx:
      tester.widget<WordDocumentView>(find.byType(WordDocumentView)).onContentTap();
    case DocumentFormat.pptx:
      tester.widget<PowerPointDocumentView>(find.byType(PowerPointDocumentView)).onContentTap();
    case DocumentFormat.txt || DocumentFormat.markdown:
      // The reader's actual pointer classifier, in the viewport's text-free
      // right padding so the test does not start word selection accidentally.
      await tester.tapAt(const Offset(400, 420));
  }
}

void _expectChrome(WidgetTester tester, bool visible) {
  final shells = tester.widgetList<ReaderChromeShell>(find.byType(ReaderChromeShell));
  expect(shells, hasLength(6));
  for (final shell in shells) {
    expect(shell.progress.value, visible ? 1 : 0);
  }
}

void _readingScroll(WidgetTester tester, DocumentFormat format, double delta) {
  switch (format) {
    case DocumentFormat.pdf:
      tester.widget<PdfDocumentView>(find.byType(PdfDocumentView)).onVerticalReadingGesture(delta);
    case DocumentFormat.docx:
      tester.widget<WordDocumentView>(find.byType(WordDocumentView)).onReadingGesture(delta);
    case DocumentFormat.txt || DocumentFormat.markdown:
      _dispatchTextScroll(tester, delta);
    case DocumentFormat.pptx:
      throw StateError('PPTX must not send reading-scroll callbacks.');
  }
}

BuildContext _textContext(WidgetTester tester) =>
    tester.element(find.byKey(const ValueKey<String>('reader_content')));

FixedScrollMetrics _metrics({AxisDirection direction = AxisDirection.down}) =>
    FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 2000,
      pixels: 400,
      viewportDimension: 915,
      axisDirection: direction,
      devicePixelRatio: 1,
    );

ScrollUpdateNotification _textScroll(
  WidgetTester tester,
  double delta, {
  bool dragged = true,
  AxisDirection direction = AxisDirection.down,
}) => ScrollUpdateNotification(
  metrics: _metrics(direction: direction),
  context: _textContext(tester),
  scrollDelta: delta,
  dragDetails: dragged ? DragUpdateDetails(globalPosition: const Offset(200, 400)) : null,
);

void _dispatchTextScroll(
  WidgetTester tester,
  double delta, {
  bool dragged = true,
  AxisDirection direction = AxisDirection.down,
}) => _textScroll(tester, delta, dragged: dragged, direction: direction).dispatch(_textContext(tester));

/// Mount PdfDocumentView and exercise its reader callbacks without starting
/// PDFium; this is intentionally not a PDF rendering or gesture-engine test.
class _PdfStub extends PdfDocumentRenderer {
  _PdfStub({required super.document, required super.contentSource}) {
    loadState = ReaderLoadState.ready;
  }

  @override
  bool get sourceReady => true;
}

class _OfficeGateway implements OfficeDocumentGateway {
  @override
  Future<OfficeDocumentSession> prepare(DocumentEntry document) async =>
      OfficeDocumentSession(
        id: 'navigation-${document.format.name}',
        format: document.format,
        sizeBytes: document.sizeBytes,
        close: () async {},
      );
}

/// Model a notification already bubbled through a nested viewport without
/// depending on the framework's private depth counter.
class _NestedScrollNotification extends ScrollUpdateNotification {
  _NestedScrollNotification(BuildContext context) : super(
    metrics: _metrics(),
    context: context,
    scrollDelta: -100,
    dragDetails: DragUpdateDetails(globalPosition: const Offset(200, 400)),
  );

  @override
  int get depth => 1;
}
