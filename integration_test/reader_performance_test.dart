// Raw reader performance harness (Task 2 baseline / Task 8 comparison).
//
// Measures per corpus file: cold open latency (time until the format view
// reports a ready renderer), a fixed settle window of FrameTiming samples,
// and repeat-open latency on the same file. Runs on a real device in
// profile/release mode; the exact procedure lives in
// tools/reader_benchmarks/README.md. Results are printed as one
// `PERF_RESULTS {json}` line that the console captures.
//
// v1 scope (recorded in docs/benchmarks/protocol.md): open latency + ready
// frame window. Scroll/pinch/scrub/search interaction windows are added to
// this same harness in Task 8, before the post-refactor comparison, so both
// sides of the comparison use one procedure.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/reader/data/document_content_source.dart';
import 'package:folio/features/reader/logic/document_renderer.dart';
import 'package:folio/features/reader/logic/reader_state.dart';
import 'package:folio/features/reader/logic/renderer_lifecycle.dart';
import 'package:folio/features/reader/widgets/bindings/reader_binding.dart';
import 'package:folio/features/reader/widgets/bindings/text_reader_binding.dart';
import 'package:folio/features/reader/office/widgets/office_document_platform_view.dart';
import 'package:folio/features/reader/pdf/widgets/pdf_document_view.dart';

/// Representative large files per format, relative to the corpus directory.
const _representativeFiles = <String>[
  'docx_big_images.docx',
  'docx_long_text.docx',
  'pptx_many_slides.pptx',
  'pptx_basic_theme.pptx',
  'text_searchable_24p.pdf',
  'image_only_4p.pdf',
  'sample_long.txt',
  'sample_long.md',
];

/// Frame budgets covered in the report, in milliseconds.
const _budgetsMs = <double>[16.67, 8.33];

/// One settle window of frames after a document becomes readable.
const _windowDuration = Duration(seconds: 3);

Duration _openTimeout(DocumentFormat format) => format == DocumentFormat.docx || format == DocumentFormat.pptx
    ? const Duration(seconds: 60)
    : const Duration(seconds: 30);

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const corpusDir = String.fromEnvironment('FOLIO_PERF_CORPUS_DIR');
  assert(
    corpusDir.isNotEmpty,
    'Pass --dart-define=FOLIO_PERF_CORPUS_DIR=/path with the pushed corpus (see tools/reader_benchmarks/README.md).',
  );

  testWidgets('reader open latency and frame window per corpus file', (tester) async {
    final results = <Map<String, Object?>>[];
    await _waitForCorpus(corpusDir);
    for (final name in _representativeFiles) {
      final file = File('$corpusDir/$name');
      if (!file.existsSync()) {
        results.add(<String, Object?>{'file': name, 'status': 'missing'});
        continue;
      }
      final entry = _entryFor(file);
      final cold = await _measureOpen(tester, entry, file);
      final window = cold.status == 'ready'
          ? await _frameWindow(tester, cold.teardown)
          : await cold.teardown().then((_) => <FrameTiming>[]);
      final repeats = <int>[];
      for (var i = 0; i < 3; i++) {
        final repeat = await _measureOpen(tester, entry, file);
        repeats.add(repeat.readyMs);
        await repeat.teardown();
      }
      results.add(<String, Object?>{
        'file': name,
        'format': entry.format.name,
        'coldReadyMs': cold.readyMs,
        'status': cold.status,
        'repeatReadyMs': repeats,
        'frames': _frameReport(window),
      });
    }
    // debugPrint wraps long lines and interleaves under load, which shreds
    // the JSON; the report therefore also lands in a file the procedure can
    // pull with adb (same directory as the corpus).
    final report = <String, Object?>{
      'device': Platform.operatingSystemVersion,
      'results': results,
    };
    final encoded = jsonEncode(report);
    try {
      File('$corpusDir/../perf_results.json').writeAsStringSync(encoded);
    } catch (error) {
      debugPrint('PERF_REPORT_FILE_FAILED $error');
    }
    // Line-split so logcat/debugPrint wrapping can never shred the JSON.
    for (final line in _splitForLog(encoded)) {
      debugPrint('PERF_RESULT_LINE $line');
    }
  });
}

/// Splits the JSON payload into stable, individually parseable chunks.
Iterable<String> _splitForLog(String text, [int chunkSize = 900]) sync* {
  for (var offset = 0; offset < text.length; offset += chunkSize) {
    yield text.substring(offset, (offset + chunkSize).clamp(0, text.length));
  }
}

/// The test runner reinstalls the app and wipes its external files dir, so
/// the corpus push happens after launch. Poll until the pushed corpus shows
/// up (or time out with an honest all-missing report).
Future<void> _waitForCorpus(String directory) async {
  final deadline = DateTime.now().add(const Duration(minutes: 3));
  while (DateTime.now().isBefore(deadline)) {
    final marker = Directory(directory);
    if (marker.existsSync() && marker.listSync().isNotEmpty) {
      return;
    }
    debugPrint('PERF_WAITING_FOR_CORPUS $directory');
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

DocumentEntry _entryFor(File file) {
  final name = file.uri.pathSegments.last;
  final format = switch (name.substring(name.lastIndexOf('.') + 1)) {
    'pdf' => DocumentFormat.pdf,
    'docx' => DocumentFormat.docx,
    'pptx' => DocumentFormat.pptx,
    'md' => DocumentFormat.markdown,
    _ => DocumentFormat.txt,
  };
  return DocumentEntry(
    id: name,
    source: FileDocumentSource(file.path),
    name: name,
    format: format,
    sizeBytes: file.lengthSync(),
    modifiedAt: DateTime.fromMillisecondsSinceEpoch(0),
  );
}

class _OpenResult {
  _OpenResult(this.readyMs, this.status, this.teardown);

  final int readyMs;
  final String status;
  final Future<void> Function() teardown;
}

/// Opens a fresh renderer, mounts the format view, and pumps until the
/// renderer reports ready (or the timeout). Returns the elapsed wall clock
/// and a teardown that releases the whole surface deterministically.
Future<_OpenResult> _measureOpen(WidgetTester tester, DocumentEntry entry, File file) async {
  final renderer = createDocumentRenderer(
    document: entry,
    contentSource: const DeviceDocumentContentSource(),
  );
  final clock = Stopwatch()..start();
  // The text binding owns the scroll resources its surface needs; the other
  // formats mount their views directly.
  ReaderBinding? binding;
  if (renderer is TextDocumentRenderer) {
    binding = TextReaderBinding(renderer);
  }
  unawaited(renderer.open());
  // Mount through a listener like production does: the Office platform view
  // can only be created after `prepare` surfaces its session, and the
  // renderer notification is what rebuilds the surface then.
  await tester.pumpWidget(
    AnimatedBuilder(
      animation: renderer,
      builder: (context, _) => _surface(renderer, binding),
    ),
  );
  final timeout = _openTimeout(entry.format);
  while (renderer.loadState == ReaderLoadState.loading && clock.elapsed < timeout) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  final status = switch (renderer.loadState) {
    ReaderLoadState.ready => 'ready',
    ReaderLoadState.failed => 'failed: ${renderer.failure?.message ?? 'unknown'}',
    ReaderLoadState.loading => 'timeout',
  };
  await tester.pump(const Duration(milliseconds: 300));
  return _OpenResult(clock.elapsedMilliseconds, status, () async {
    await tester.pumpWidget(const SizedBox.shrink());
    releaseDocumentRenderer(renderer);
    binding?.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });
}

/// Minimal real surface per format: the actual platform/compositor views the
/// reader uses, without library chrome. This is what makes `ready` mean
/// "first readable content" for PDF (viewer attached) and Office (WebView
/// posted its ready event) instead of a background prepare step. Text builds
/// its real document view too — otherwise the frame window would measure an
/// empty scene.
Widget _surface(DocumentRenderer renderer, ReaderBinding? binding) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery.fromView(
      view: WidgetsBinding.instance.platformDispatcher.views.first,
      child: switch (renderer) {
        PdfDocumentRenderer() => PdfDocumentView(
            renderer: renderer,
            onContentTap: () {},
            onVerticalReadingGesture: (_) {},
          ),
        OfficeDocumentRendererBase() => OfficeDocumentPlatformView(
            renderer: renderer,
            onContentTap: () {},
          ),
        TextDocumentRenderer() => binding!.buildSurface(
            const ReaderSurfaceCallbacks(
              onContentTap: _noop,
              onReadingDrag: _noopDrag,
              onSelectionChanged: _noopSelection,
            ),
          ),
        _ => const SizedBox.shrink(),
      },
    ),
  );
}

void _noop() {}
void _noopDrag(double delta, bool canHide) {}
void _noopSelection(bool active) {}

Map<String, Object?> _frameReport(List<FrameTiming> frames) {
  if (frames.isEmpty) {
    return <String, Object?>{'count': 0};
  }
  final ui = frames.map((frame) => frame.buildDuration.inMicroseconds / 1000).toList()..sort();
  final raster = frames.map((frame) => frame.rasterDuration.inMicroseconds / 1000).toList()..sort();
  double percentile(List<double> values, double p) =>
      values[math.min(values.length - 1, (p * (values.length - 1)).round())];
  return <String, Object?>{
    'count': frames.length,
    'uiMs': {
      'p50': percentile(ui, 0.5),
      'p95': percentile(ui, 0.95),
      'p99': percentile(ui, 0.99),
    },
    'rasterMs': {
      'p50': percentile(raster, 0.5),
      'p95': percentile(raster, 0.95),
      'p99': percentile(raster, 0.99),
    },
    'overBudgetShare': {
      for (final budget in _budgetsMs)
        '$budget': frames
                .where((frame) => frame.buildDuration.inMicroseconds / 1000 > budget ||
                    frame.rasterDuration.inMicroseconds / 1000 > budget)
                .length /
            frames.length,
    },
  };
}

Future<List<FrameTiming>> _frameWindow(WidgetTester tester, Future<void> Function() teardown) async {
  final frames = <FrameTiming>[];
  void collect(List<FrameTiming> timings) => frames.addAll(timings);
  SchedulerBinding.instance.addTimingsCallback(collect);
  final deadline = DateTime.now().add(_windowDuration);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  SchedulerBinding.instance.removeTimingsCallback(collect);
  await teardown();
  return frames;
}
