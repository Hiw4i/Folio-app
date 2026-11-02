// Memory-pressure cycles: open and close representative documents N times
// with pauses, so the external PSS procedure (tools/reader_benchmarks/README.md
// §2) can sample the process before and after. Any unbounded session, texture
// or cache growth shows up as a residual PSS delta.
//
// Run: flutter run --profile -d <device> integration_test/reader_memory_cycles_test.dart
// (same corpus-push choreography as the performance harness).
import 'dart:async';
import 'dart:io';

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

const _corpusDir = String.fromEnvironment('FOLIO_PERF_CORPUS_DIR');
const _cycleFiles = <String>['docx_big_images.docx', 'text_searchable_24p.pdf'];
const _cyclesPerFile = 20;
const _settleBetweenCycles = Duration(milliseconds: 500);

Duration _openTimeout(DocumentFormat format) =>
    format == DocumentFormat.docx || format == DocumentFormat.pptx
        ? const Duration(seconds: 60)
        : const Duration(seconds: 30);

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  assert(
    _corpusDir.isNotEmpty,
    'Pass --dart-define=FOLIO_PERF_CORPUS_DIR=/path with the pushed corpus.',
  );

  testWidgets('20 open/close cycles per file stay stable', (tester) async {
    for (final name in _cycleFiles) {
      final file = File('$_corpusDir/$name');
      if (!file.existsSync()) {
        debugPrint('MEM_CYCLES $name: corpus file missing, skipped');
        continue;
      }
      final entry = _entryFor(file);
      var readyCount = 0;
      for (var cycle = 1; cycle <= _cyclesPerFile; cycle++) {
        final renderer = createDocumentRenderer(
          document: entry,
          contentSource: const DeviceDocumentContentSource(),
        );
        final clock = Stopwatch()..start();
        unawaited(renderer.open());
        await tester.pumpWidget(
          AnimatedBuilder(
            animation: renderer,
            builder: (context, _) => _surface(renderer),
          ),
        );
        while (renderer.loadState == ReaderLoadState.loading &&
            clock.elapsed < _openTimeout(entry.format)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        if (renderer.loadState == ReaderLoadState.ready) {
          readyCount += 1;
        }
        await tester.pump(_settleBetweenCycles);
        await tester.pumpWidget(const SizedBox.shrink());
        releaseDocumentRenderer(renderer);
        await tester.pump(_settleBetweenCycles);
      }
      debugPrint(
        'MEM_CYCLES $name: $_cyclesPerFile cycles, $readyCount reached ready',
      );
    }
  });
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

Widget _surface(DocumentRenderer renderer) {
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
        _ => const SizedBox.shrink(),
      },
    ),
  );
}
