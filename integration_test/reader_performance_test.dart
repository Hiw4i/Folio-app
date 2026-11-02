// Raw reader performance harness (Task 2 baseline / Task 8 comparison).
//
// v2 scope: per corpus file — one fresh-process cold open, 10 cache-warm
// repeat opens, a 3 s settle window and a 10 s DRIVEN window where the
// harness sweeps seek/scroll through the same renderer APIs the production
// navigation adapters call. The harness deliberately uses renderer APIs (not
// the binding layer) so the baseline checkout and the refactored checkout
// execute identical measurement code. The full Task-8 campaign adds
// multi-process cold counts and search/selection scenarios
// (docs/benchmarks/protocol.md).
//
// Results are written to `<corpusDir>/../perf_results.json` and printed as
// `PERF_RESULT_LINE` chunks (logcat/debugPrint cannot carry one long line).
//
// Run procedure: tools/reader_benchmarks/README.md §1.
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
import 'package:folio/features/reader/office/widgets/office_document_platform_view.dart';
import 'package:folio/features/reader/pdf/widgets/pdf_document_view.dart';
import 'package:folio/features/reader/text/widgets/text_document_view.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

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

/// Settle window of frames after a document becomes readable.
const _settleWindowDuration = Duration(seconds: 3);

/// Driven interaction window: seek/scroll sweeps through renderer APIs.
const _drivenWindowDuration = Duration(seconds: 10);

/// Cache-warm repeat opens per file (protocol repeat minimum).
const _repeatOpens = 10;

Duration _openTimeout(DocumentFormat format) =>
    format == DocumentFormat.docx || format == DocumentFormat.pptx
        ? const Duration(seconds: 60)
        : const Duration(seconds: 30);

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const corpusDir = String.fromEnvironment('FOLIO_PERF_CORPUS_DIR');
  assert(
    corpusDir.isNotEmpty,
    'Pass --dart-define=FOLIO_PERF_CORPUS_DIR=/path with the pushed corpus (see tools/reader_benchmarks/README.md).',
  );

  testWidgets('reader open latency and frame windows per corpus file', (
    tester,
  ) async {
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
      var settle = <FrameTiming>[];
      var driven = <FrameTiming>[];
      if (cold.status == 'ready') {
        settle = await _settleWindow(tester);
        driven = await _drivenWindow(tester, cold.drivers);
        await cold.teardown();
      } else {
        await cold.teardown();
      }
      final repeats = <int>[];
      for (var i = 0; i < _repeatOpens; i++) {
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
        'frames': _frameReport(settle),
        'drivenFrames': _frameReport(driven),
      });
    }
    _emitReport(corpusDir, results);
  });
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

void _emitReport(String corpusDir, List<Map<String, Object?>> results) {
  // debugPrint wraps long lines and interleaves under load, which shreds
  // the JSON; the report therefore also lands in a file the procedure can
  // pull with adb (next to the corpus).
  final encoded = jsonEncode(<String, Object?>{
    'device': Platform.operatingSystemVersion,
    'results': results,
  });
  try {
    File('$corpusDir/../perf_results.json').writeAsStringSync(encoded);
  } catch (error) {
    debugPrint('PERF_REPORT_FILE_FAILED $error');
  }
  // Line-split so logcat/debugPrint wrapping can never shred the JSON.
  for (var offset = 0; offset < encoded.length; offset += 900) {
    debugPrint(
      'PERF_RESULT_LINE ${encoded.substring(offset, (offset + 900).clamp(0, encoded.length))}',
    );
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
  _OpenResult(this.readyMs, this.status, this.teardown, this.drivers);

  final int readyMs;
  final String status;
  final Future<void> Function() teardown;

  /// Drive hooks for the interaction window; null when the format offers no
  /// in-process seek/scroll surface.
  final _DriveDrivers? drivers;
}

/// The seek/scroll controls the driven window sweeps. They are the exact
/// APIs the production navigation adapters call, so both sides of the
/// pre/post comparison measure the same underlying work.
class _DriveDrivers {
  _DriveDrivers({this.seek, this.scroll});

  final Future<void> Function(double fraction)? seek;
  final AutoScrollController? scroll;
}

/// Opens a fresh renderer, mounts the format view, and pumps until the
/// renderer reports ready (or the timeout). Returns the elapsed wall clock
/// and a teardown that releases the whole surface deterministically.
Future<_OpenResult> _measureOpen(
  WidgetTester tester,
  DocumentEntry entry,
  File file,
) async {
  final renderer = createDocumentRenderer(
    document: entry,
    contentSource: const DeviceDocumentContentSource(),
  );
  final scrollController = AutoScrollController(
    axis: Axis.vertical,
    suggestedRowHeight: 3200,
  );
  final clock = Stopwatch()..start();
  unawaited(renderer.open());
  // Mount through a listener like production does: the Office platform view
  // can only be created after `prepare` surfaces its session, and the
  // renderer notification is what rebuilds the surface then.
  await tester.pumpWidget(
    AnimatedBuilder(
      animation: renderer,
      builder: (context, _) => _surface(renderer, scrollController),
    ),
  );
  final timeout = _openTimeout(entry.format);
  while (renderer.loadState == ReaderLoadState.loading &&
      clock.elapsed < timeout) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  final status = switch (renderer.loadState) {
    ReaderLoadState.ready => 'ready',
    ReaderLoadState.failed => 'failed: ${renderer.failure?.message ?? 'unknown'}',
    ReaderLoadState.loading => 'timeout',
  };
  await tester.pump(const Duration(milliseconds: 300));
  return _OpenResult(
    clock.elapsedMilliseconds,
    status,
    () async {
      await tester.pumpWidget(const SizedBox.shrink());
      releaseDocumentRenderer(renderer);
      scrollController.dispose();
      await tester.pump(const Duration(milliseconds: 100));
    },
    _driversFor(renderer, scrollController),
  );
}

_DriveDrivers? _driversFor(
  DocumentRenderer renderer,
  AutoScrollController scrollController,
) {
  return switch (renderer) {
    PdfDocumentRenderer() => _DriveDrivers(seek: renderer.seekToFraction),
    OfficeDocumentRendererBase() => _DriveDrivers(
      seek: renderer.seekToFraction,
    ),
    TextDocumentRenderer() => _DriveDrivers(scroll: scrollController),
    _ => null,
  };
}

/// Minimal real surface per format: the actual platform/compositor views the
/// reader uses, without library chrome. This is what makes `ready` mean
/// "first readable content" for PDF (viewer attached) and Office (WebView
/// posted its ready event) instead of a background prepare step. Text builds
/// its real document view too — otherwise the frame windows would measure an
/// empty scene.
Widget _surface(DocumentRenderer renderer, AutoScrollController scrollController) {
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
        TextDocumentRenderer() => TextDocumentView(
            renderer: renderer,
            scrollController: scrollController,
            activeHitKey: GlobalKey(),
          ),
        _ => const SizedBox.shrink(),
      },
    ),
  );
}

Map<String, Object?> _frameReport(List<FrameTiming> frames) {
  if (frames.isEmpty) {
    return <String, Object?>{'count': 0};
  }
  final ui =
      frames.map((frame) => frame.buildDuration.inMicroseconds / 1000).toList()
        ..sort();
  final raster =
      frames.map((frame) => frame.rasterDuration.inMicroseconds / 1000).toList()
        ..sort();
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
        '$budget':
            frames
                .where(
                  (frame) =>
                      frame.buildDuration.inMicroseconds / 1000 > budget ||
                      frame.rasterDuration.inMicroseconds / 1000 > budget,
                )
                .length /
            frames.length,
    },
  };
}

Future<List<FrameTiming>> _settleWindow(WidgetTester tester) async {
  final frames = <FrameTiming>[];
  void collect(List<FrameTiming> timings) => frames.addAll(timings);
  SchedulerBinding.instance.addTimingsCallback(collect);
  final deadline = DateTime.now().add(_settleWindowDuration);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  SchedulerBinding.instance.removeTimingsCallback(collect);
  return frames;
}

/// Sweeps seek/scroll through the same renderer APIs the production
/// navigation adapters call, so the window covers real rasterization and
/// scroll work instead of a static frame. The caller releases the surface
/// once both windows are collected.
Future<List<FrameTiming>> _drivenWindow(
  WidgetTester tester,
  _DriveDrivers? drivers,
) async {
  final frames = <FrameTiming>[];
  void collect(List<FrameTiming> timings) => frames.addAll(timings);
  SchedulerBinding.instance.addTimingsCallback(collect);
  if (drivers != null) {
    final deadline = DateTime.now().add(_drivenWindowDuration);
    var forward = true;
    var fraction = 0.0;
    while (DateTime.now().isBefore(deadline)) {
      fraction += forward ? 0.04 : -0.04;
      if (fraction >= 1.0) {
        fraction = 1.0;
        forward = false;
      } else if (fraction <= 0.0) {
        fraction = 0.0;
        forward = true;
      }
      final seek = drivers.seek;
      if (seek != null) {
        await seek(fraction);
      } else if (drivers.scroll case final scroll?) {
        if (scroll.hasClients) {
          final position = scroll.position;
          scroll.jumpTo(fraction * position.maxScrollExtent);
        }
      }
      await tester.pump(const Duration(milliseconds: 80));
    }
  }
  SchedulerBinding.instance.removeTimingsCallback(collect);
  return frames;
}
