import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/reader/logic/document_renderer.dart';
import 'package:folio/features/reader/logic/reader_search_state.dart';
import 'package:folio/features/reader/logic/reader_state.dart';
import 'package:folio/features/reader/logic/unsupported_document_renderer.dart';

import '../../support/reader_stubs.dart';

void main() {
  group('ReaderSearchSnapshot', () {
    const base = ReaderSearchSnapshot(
      query: 'word',
      phase: ReaderSearchPhase.complete,
      textAvailability: ReaderTextAvailability.present,
      hitCount: 3,
      activeHitIndex: 1,
    );

    test('snapshots with identical values are equal', () {
      const same = ReaderSearchSnapshot(
        query: 'word',
        phase: ReaderSearchPhase.complete,
        textAvailability: ReaderTextAvailability.present,
        hitCount: 3,
        activeHitIndex: 1,
      );
      expect(base == same, isTrue);
      expect(base.hashCode, same.hashCode);
    });

    test('a changed field produces a different snapshot', () {
      expect(
        base,
        isNot(
          const ReaderSearchSnapshot(
            query: 'word',
            phase: ReaderSearchPhase.searching,
            textAvailability: ReaderTextAvailability.present,
            hitCount: 3,
            activeHitIndex: 1,
          ),
        ),
      );
      expect(
        base,
        isNot(
          const ReaderSearchSnapshot(
            query: 'other',
            phase: ReaderSearchPhase.complete,
            textAvailability: ReaderTextAvailability.present,
            hitCount: 3,
            activeHitIndex: 1,
          ),
        ),
      );
      expect(
        base,
        isNot(
          const ReaderSearchSnapshot(
            query: 'word',
            phase: ReaderSearchPhase.complete,
            textAvailability: ReaderTextAvailability.absent,
            hitCount: 3,
            activeHitIndex: 1,
          ),
        ),
      );
      expect(
        base,
        isNot(
          const ReaderSearchSnapshot(
            query: 'word',
            phase: ReaderSearchPhase.complete,
            textAvailability: ReaderTextAvailability.present,
            hitCount: 4,
            activeHitIndex: 1,
          ),
        ),
      );
      expect(
        base,
        isNot(
          const ReaderSearchSnapshot(
            query: 'word',
            phase: ReaderSearchPhase.complete,
            textAvailability: ReaderTextAvailability.present,
            hitCount: 3,
            activeHitIndex: 2,
          ),
        ),
      );
    });
  });

  group('PDF search state projection', () {
    test('an unknown text layer differs from an absent one', () {
      final renderer = PdfRendererStub()..query = 'word';
      expect(
        renderer.searchState.textAvailability,
        ReaderTextAvailability.unknown,
      );
      renderer.searchableTextAvailable = false;
      expect(
        renderer.searchState.textAvailability,
        ReaderTextAvailability.absent,
      );
      renderer.searchableTextAvailable = true;
      expect(
        renderer.searchState.textAvailability,
        ReaderTextAvailability.present,
      );
    });

    test('a query before the source is prepared waits instead of completing', () {
      final renderer = PdfRendererStub()
        ..query = 'word'
        ..isSearching = true;
      expect(
        renderer.searchState.phase,
        ReaderSearchPhase.waitingForSource,
      );
    });

    test('a prepared source without an attached searcher is not "no matches"', () {
      // Real window: the document ref exists but the viewer has not attached
      // yet, so no search can have run — zero hits must read as waiting.
      final renderer = PdfRendererStub()
        ..pdfSourceReady = true
        ..query = 'word';
      expect(
        renderer.searchState.phase,
        ReaderSearchPhase.waitingForSource,
      );
    });

    // Stub note: the stub's _textSearcher is always null (it is private and
    // set by attachViewer), so "searcher attached + finished + 0 hits →
    // complete" is represented here via stubHits > 0. With a live searcher
    // the waiting clause (`_textSearcher == null`) cannot fire.
    test('an active search reports searching, a finished one completes', () {
      final renderer = PdfRendererStub()
        ..pdfSourceReady = true
        ..query = 'word'
        ..isSearching = true;
      expect(
        renderer.searchState.phase,
        ReaderSearchPhase.searching,
      );
      renderer.isSearching = false;
      renderer.stubHits = 2;
      final snapshot = renderer.searchState;
      expect(snapshot.phase, ReaderSearchPhase.complete);
      expect(snapshot.hitCount, 2);
    });

    test('an empty query is idle regardless of the rest', () {
      final renderer = PdfRendererStub()
        ..pdfSourceReady = true
        ..isSearching = true;
      expect(renderer.searchState.phase, ReaderSearchPhase.idle);
    });
  });

  group('text search state projection', () {
    test('no content is unknown, loaded content is present', () {
      final renderer = TextRendererStub()..query = 'word';
      expect(
        renderer.searchState.textAvailability,
        ReaderTextAvailability.unknown,
      );
      expect(
        renderer.searchState.phase,
        ReaderSearchPhase.waitingForSource,
      );
      renderer.loadState = ReaderLoadState.ready;
      expect(
        renderer.searchState.textAvailability,
        ReaderTextAvailability.present,
      );
      expect(
        renderer.searchState.phase,
        ReaderSearchPhase.complete,
      );
    });

    test('an unsupported encoding is not an absent text layer', () {
      final renderer = TextRendererStub()
        ..loadState = ReaderLoadState.failed
        ..failure = const ReaderFailure(
          kind: ReaderFailureKind.unsupportedEncoding,
          title: 'Unsupported text encoding',
          message: 'Folio can read UTF-8 and BOM-marked UTF-16 text files.',
        );
      expect(
        renderer.searchState.textAvailability,
        ReaderTextAvailability.unsupported,
      );
    });

    test('a search failure is not reported as zero results', () {
      final renderer = TextRendererStub()
        ..loadState = ReaderLoadState.ready
        ..query = 'word'
        ..searchFailure = const ReaderFailure(
          kind: ReaderFailureKind.unreadable,
          title: 'Search failed',
          message: 'isolate died',
        );
      final snapshot = renderer.searchState;
      expect(snapshot.phase, ReaderSearchPhase.failed);
      expect(snapshot.failure, isNotNull);
      expect(snapshot.hitCount, 0);
    });
  });

  group('Office search state projection', () {
    test('the bridge hasText flag maps to availability', () async {
      final renderer = OfficeRendererStub(document: stubEntry('doc.docx'));
      renderer.officeSourceReady = true;
      await renderer.open();
      renderer.query = 'word';
      renderer.handleViewEvent(<Object?, Object?>{
        'type': 'ready',
        'count': 6,
        'hasText': true,
      });
      expect(
        renderer.searchState.textAvailability,
        ReaderTextAvailability.present,
      );
      renderer.handleViewEvent(<Object?, Object?>{
        'type': 'ready',
        'count': 6,
        'hasText': false,
      });
      expect(
        renderer.searchState.textAvailability,
        ReaderTextAvailability.absent,
      );
      renderer.handleViewEvent(<Object?, Object?>{'type': 'ready', 'count': 6});
      expect(
        renderer.searchState.textAvailability,
        ReaderTextAvailability.unknown,
      );
      renderer.dispose();
    });

    test('a failing search command surfaces an error, not zero results', () async {
      final renderer = OfficeRendererStub(document: stubEntry('doc.docx'));
      renderer.officeSourceReady = true;
      await renderer.open();
      final view = RecordingOfficeView(searchError: StateError('channel died'));
      renderer.attachView(view, renderer.session!.id);
      renderer.handleViewEvent(<Object?, Object?>{
        'type': 'ready',
        'count': 6,
        'hasText': true,
      });
      await renderer.search('word');
      final snapshot = renderer.searchState;
      expect(snapshot.phase, ReaderSearchPhase.failed);
      expect(snapshot.failure, isNotNull);
      expect(snapshot.hitCount, 0);
      renderer.dispose();
    });
  });

  group('unsupported renderer search state', () {
    test('reports an unsupported layer without inventing a search phase', () {
      final renderer = UnsupportedDocumentRenderer(stubEntry('stub.txt'));
      expect(
        renderer.searchState.textAvailability,
        ReaderTextAvailability.unsupported,
      );
      expect(renderer.searchState.phase, ReaderSearchPhase.idle);
    });
  });
}
