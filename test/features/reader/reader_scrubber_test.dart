import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/app/folio_app.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/library/data/in_memory_library_repository.dart';
import 'package:folio/features/reader/data/document_content_source.dart';

void main() {
  DocumentEntry entry(String name, String path) => DocumentEntry(
    id: path,
    source: FileDocumentSource(path),
    name: name,
    format: DocumentFormat.txt,
    sizeBytes: 120,
    modifiedAt: DateTime.utc(2026, 9, 13),
  );

  Future<void> openReader(
    WidgetTester tester, {
    required String name,
    required String body,
  }) async {
    final path = '/documents/$name';
    await tester.pumpWidget(
      FolioApp(
        libraryRepository: InMemoryLibraryRepository(
          documents: <DocumentEntry>[entry(name, path)],
        ),
        documentContentSource: MemoryDocumentContentSource(<String, Uint8List>{
          path: Uint8List.fromList(utf8.encode(body)),
        }),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(name));
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      if (find
          .byKey(const ValueKey<String>('reader_content'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }
    await tester.pumpAndSettle();
  }

  testWidgets('long file shows the knob, pill only while held', (tester) async {
    await openReader(
      tester,
      name: 'Scrub.txt',
      body:
          'Quiet text.\n\n'
          '${List<String>.filled(120, 'A calm line for scrolling.\n\n').join()}',
    );

    // Only the small knob is interactive; the liquid-glass pill with the
    // `%` label appears only while the knob is held, so it never
    // duplicates the bottom-left `_ProgressPill` text.
    expect(
      find.byKey(const ValueKey<String>('reader_scrub_grip')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('reader_scrub_pill')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('reader_progress_glass')),
      findsOneWidget,
    );
  });

  testWidgets('short file shows no scrubber at all', (tester) async {
    await openReader(
      tester,
      name: 'Short.txt',
      body: 'Just a couple of lines.\n\nNothing to scrub.\n',
    );

    expect(
      find.byKey(const ValueKey<String>('reader_scrub_grip')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('reader_scrub_pill')),
      findsNothing,
    );
    // The bottom-left indicator is untouched.
    expect(
      find.byKey(const ValueKey<String>('reader_progress_glass')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('knob drag jumps; the pill itself ignores touches', (
    tester,
  ) async {
    await openReader(
      tester,
      name: 'Scrub.txt',
      body:
          'Quiet text.\n\n'
          '${List<String>.filled(120, 'A calm line for scrolling.\n\n').join()}',
    );

    final grip = find.byKey(const ValueKey<String>('reader_scrub_grip'));
    expect(grip, findsOneWidget);

    // Grab off-center (lower half of the knob, clear of the menu button's
    // glass overflow hit zone): with absolute mapping the knob would
    // teleport its center under the finger here.
    final gripCenter = tester.getCenter(grip);
    final gesture = await tester.startGesture(
      gripCenter + const Offset(0, 20),
    );
    await gesture.moveBy(const Offset(0, 25));
    await tester.pump();
    // No snap-to-finger teleport on grab: the knob barely moved (only the
    // drag delta past touch slop), instead of jumping ~45pt to the finger.
    final startedCenter = tester.getCenter(grip);
    expect(startedCenter.dy - gripCenter.dy, lessThan(35));
    // The drag engaged: the pill with the live `%` label floats next to
    // the knob — wrapped in IgnorePointer, so pressing it does nothing.
    final pill = find.byKey(const ValueKey<String>('reader_scrub_pill'));
    expect(pill, findsOneWidget);
    expect(
      find.ancestor(of: pill, matching: find.byType(IgnorePointer)),
      findsWidgets,
    );

    // 1:1 tracking: in steady state the knob follows the finger exactly,
    // with no snap-to-finger teleport.
    final midCenter = tester.getCenter(grip);
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();
    final endCenter = tester.getCenter(grip);
    expect((endCenter.dy - midCenter.dy - 60).abs(), lessThan(8));

    await gesture.moveBy(const Offset(0, 220));
    await tester.pump();

    await gesture.up();
    await tester.pumpAndSettle();
    // The drag scrubbed far down: the document actually jumped.
    expect(find.text('0%'), findsNothing);
    // Released: the pill is gone, the bottom-left indicator stays.
    expect(pill, findsNothing);
    expect(
      find.byKey(const ValueKey<String>('reader_progress_glass')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
