import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/reader/office/data/office_document_gateway.dart';
import 'package:folio/features/reader/word/logic/word_document_renderer.dart';

DocumentEntry _entry(String name) {
  final source = FileDocumentSource('/documents/$name');
  return DocumentEntry(
    id: stableDocumentId(source),
    source: source,
    name: name,
    format: DocumentFormat.docx,
    sizeBytes: 4096,
    modifiedAt: DateTime.utc(2026, 11, 1),
  );
}

/// A view whose instant jumps park on a completer until the test releases
/// them, so in-flight seek windows are fully controllable.
class _GatedOfficeView implements OfficeViewCommands {
  final List<int> instantJumps = <int>[];
  final List<Completer<void>> gates = <Completer<void>>[];
  int failNextJumpWith = 0;

  void completeFirstGate() {
    if (gates.isNotEmpty) {
      gates.removeAt(0).complete();
    }
  }

  @override
  Future<void> goToPosition(int zeroBasedIndex) async {}

  @override
  Future<void> goToPositionInstant(int zeroBasedIndex) {
    instantJumps.add(zeroBasedIndex);
    if (failNextJumpWith > 0) {
      failNextJumpWith -= 1;
      return Future<void>.error(StateError('bridge died'));
    }
    final gate = Completer<void>();
    gates.add(gate);
    return gate.future;
  }

  @override
  Future<void> search(String query) async {}

  @override
  Future<void> showNextHit() async {}

  @override
  Future<void> showPreviousHit() async {}

  @override
  Future<void> closeOverview() async {}
}

class _CountingCloseGateway implements OfficeDocumentGateway {
  int sessionCount = 0;

  @override
  Future<OfficeDocumentSession> prepare(DocumentEntry document) async {
    sessionCount += 1;
    return OfficeDocumentSession(
      id: 'session-$sessionCount',
      format: document.format,
      sizeBytes: document.sizeBytes,
      close: () async {},
    );
  }
}

void main() {
  late WordDocumentRenderer renderer;

  setUp(() {
    renderer = WordDocumentRenderer(
      document: _entry('seek.docx'),
      gateway: _CountingCloseGateway(),
    );
  });

  tearDown(() => renderer.dispose());

  Future<_GatedOfficeView> attachReadyView() async {
    await renderer.open();
    final view = _GatedOfficeView();
    renderer.attachView(view, renderer.session!.id);
    renderer.handleViewEvent(<Object?, Object?>{
      'type': 'ready',
      'count': 10,
      'hasText': true,
    });
    return view;
  }

  testWidgets('rapid seeks coalesce: queue bounded, last target not lost', (
    tester,
  ) async {
    final view = await attachReadyView();

    final first = renderer.seekToFraction(0.1);
    await tester.pump();
    // (0.1 * 9).round() == 1: the first jump dispatched immediately.
    expect(view.instantJumps, <int>[1]);

    // Two more seeks while the first is still in flight: only the latest
    // survives (the queue holds one pending target, no pile-up).
    unawaited(renderer.seekToFraction(0.7));
    unawaited(renderer.seekToFraction(0.95));
    await tester.pump();
    expect(view.instantJumps, <int>[1]);

    view.completeFirstGate();
    await tester.pump();
    // The intermediate 0.7 was skipped; the final 0.95 landed: index 9.
    expect(view.instantJumps, <int>[1, 9]);

    // Release the second gate so the drain itself completes.
    view.completeFirstGate();
    await tester.pump();
    await first;
    expect(tester.takeException(), isNull);
  });

  testWidgets('close mid-seek never resumes the drain into a new session', (
    tester,
  ) async {
    final view = await attachReadyView();

    unawaited(renderer.seekToFraction(0.1));
    await tester.pump();
    expect(view.instantJumps, <int>[1]);

    await renderer.close();
    await renderer.open();
    final secondView = _GatedOfficeView();
    renderer.attachView(secondView, renderer.session!.id);
    renderer.handleViewEvent(<Object?, Object?>{
      'type': 'ready',
      'count': 10,
      'hasText': true,
    });

    // The old in-flight jump completes after the reopen: the stale drain
    // must exit instead of driving the new session.
    view.completeFirstGate();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(secondView.instantJumps, isEmpty);
    // The new session accepts seeks again: dispatch lands, then the gate is
    // released so the drain completes.
    final secondSeek = renderer.seekToFraction(0.5);
    await tester.pump();
    expect(secondView.instantJumps, <int>[(0.5 * 9).round()]);
    secondView.completeFirstGate();
    await tester.pump();
    await secondSeek;
  });

  testWidgets('a bridge error during seek is not fatal and unblocks the next seek', (
    tester,
  ) async {
    final view = await attachReadyView();
    view.failNextJumpWith = 1;

    await renderer.seekToFraction(0.3);
    await tester.pump();
    expect(view.instantJumps, hasLength(1));

    // The failed command must not wedge the coalescer: the next seek runs.
    final retry = renderer.seekToFraction(0.8);
    await tester.pump();
    expect(view.instantJumps, hasLength(2));
    expect(view.instantJumps.last, (0.8 * 9).round());
    view.completeFirstGate();
    await tester.pump();
    await retry;
    expect(tester.takeException(), isNull);
  });

  testWidgets('seeks against an unready view are dropped silently', (
    tester,
  ) async {
    await renderer.open();
    final view = _GatedOfficeView();
    renderer.attachView(view, renderer.session!.id);
    // No ready event: positionCount is 0 and the view is not marked ready.
    await renderer.seekToFraction(0.5);
    await tester.pump();
    expect(view.instantJumps, isEmpty);
    // Settle the ready watchdog the way the real flow would.
    renderer.handleViewEvent(<Object?, Object?>{
      'type': 'ready',
      'count': 10,
      'hasText': true,
    });
    await tester.pump();
  });
}
