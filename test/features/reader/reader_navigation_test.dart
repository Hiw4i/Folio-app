import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/reader/logic/reader_navigation.dart';
import 'package:folio/features/reader/logic/reader_state.dart';
import 'package:folio/features/reader/widgets/bindings/office_reader_navigation.dart';
import 'package:folio/features/reader/widgets/bindings/pdf_reader_navigation.dart';
import 'package:folio/features/reader/widgets/bindings/text_reader_navigation.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import '../../support/reader_stubs.dart';

void main() {
  group('fraction normalization', () {
    test('non-finite fractions are rejected, finite ones clamp', () {
      expect(normalizeScrubFraction(double.nan), isNull);
      expect(normalizeScrubFraction(double.infinity), isNull);
      expect(normalizeScrubFraction(double.negativeInfinity), isNull);
      expect(normalizeScrubFraction(-0.2), 0.0);
      expect(normalizeScrubFraction(0.4), 0.4);
      expect(normalizeScrubFraction(1.5), 1.0);
    });
  });

  group('PDF navigation', () {
    test('before any measurement position is unknown and seek is disabled', () {
      final renderer = PdfRendererStub();
      final navigation = PdfReaderNavigation(renderer);
      addTearDown(navigation.dispose);

      final snapshot = navigation.snapshot;
      expect(snapshot.confirmedFraction, isNull);
      expect(snapshot.canSeek, isFalse);
      expect(snapshot.showScrubber, isFalse);
      expect(snapshot.kind, ReaderPositionKind.pages);
      expect(snapshot.positionLabel, 'PDF');
      expect(snapshot.currentPosition, isNull);
      expect(snapshot.positionCount, isNull);
    });

    test('the confirmed fraction is continuous, not the rounded page', () {
      final renderer = PdfRendererStub()
        ..pdfSourceReady = true
        ..pageCount = 10
        ..currentPage = 3
        ..scrollFraction.value = 0.42;
      final navigation = PdfReaderNavigation(renderer);
      addTearDown(navigation.dispose);

      expect(navigation.snapshot.confirmedFraction, closeTo(0.42, 1e-9));
      expect(navigation.snapshot.canSeek, isTrue);
      expect(navigation.snapshot.showScrubber, isTrue);
      expect(navigation.snapshot.currentPosition, 3);
      expect(navigation.snapshot.positionCount, 10);
      expect(
        navigation.snapshot.minimumSeekInterval,
        const Duration(milliseconds: 80),
      );
    });

    test('before the viewer matrix the page fraction is the fallback', () {
      final renderer = PdfRendererStub()
        ..pdfSourceReady = true
        ..pageCount = 4
        ..currentPage = 2;
      final navigation = PdfReaderNavigation(renderer);
      addTearDown(navigation.dispose);

      expect(navigation.snapshot.confirmedFraction, closeTo(1 / 3, 1e-9));
    });

    test('a two-page document stays hidden, three pages show the scrubber', () {
      final renderer = PdfRendererStub()..pdfSourceReady = true;
      final navigation = PdfReaderNavigation(renderer);
      addTearDown(navigation.dispose);

      renderer.pageCount = 2;
      renderer.notifyListeners();
      expect(navigation.snapshot.showScrubber, isFalse);
      renderer.pageCount = 3;
      renderer.notifyListeners();
      expect(navigation.snapshot.showScrubber, isTrue);
    });

    test('non-finite seek targets never reach the renderer', () async {
      final renderer = PdfRendererStub()..pdfSourceReady = true;
      final navigation = PdfReaderNavigation(renderer);
      addTearDown(navigation.dispose);

      await navigation.seekToFraction(double.nan);
      await navigation.seekToFraction(1.7);
      expect(renderer.recordedSeeks, <double>[1.0]);
    });

    test('unchanged snapshots do not notify twice', () {
      final renderer = PdfRendererStub()
        ..pdfSourceReady = true
        ..pageCount = 10;
      final navigation = PdfReaderNavigation(renderer);
      addTearDown(navigation.dispose);

      var notifications = 0;
      navigation.addListener(() => notifications++);
      // The page-based fallback (page 1 of 10) is a measured position.
      expect(navigation.snapshot.confirmedFraction, closeTo(0.0, 1e-9));
      renderer.notifyListeners();
      expect(notifications, 0);

      renderer.scrollFraction.value = 0.5;
      expect(notifications, 1);
      // A second notify with no further change stays silent.
      renderer.notifyListeners();
      expect(notifications, 1);
    });
  });

  group('text navigation', () {
    testWidgets(
      'a detached viewport reports unknown position and never seeks',
      (tester) async {
        final renderer = TextRendererStub()..loadState = ReaderLoadState.ready;
        final controller = AutoScrollController();
        final progress = ValueNotifier<int>(0);
        final navigation = TextReaderNavigation(
          renderer: renderer,
          scrollController: controller,
          progressPercent: progress,
        );
        addTearDown(navigation.dispose);
        addTearDown(controller.dispose);
        addTearDown(progress.dispose);

        final snapshot = navigation.snapshot;
        expect(snapshot.confirmedFraction, isNull);
        expect(snapshot.canSeek, isFalse);
        expect(snapshot.showScrubber, isFalse);
        expect(snapshot.kind, ReaderPositionKind.flow);
        expect(snapshot.positionLabel, '0%');

        await navigation.seekToFraction(0.5);
        // No clients attached: the jump must not happen (and would assert).
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('flow position follows the scroll position', (tester) async {
      final renderer = TextRendererStub()..loadState = ReaderLoadState.ready;
      final controller = AutoScrollController();
      final progress = ValueNotifier<int>(42);
      final navigation = TextReaderNavigation(
        renderer: renderer,
        scrollController: controller,
        progressPercent: progress,
      );
      addTearDown(navigation.dispose);
      addTearDown(controller.dispose);
      addTearDown(progress.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomScrollView(
            controller: controller,
            slivers: <Widget>[
              SliverToBoxAdapter(
                child: SizedBox(height: 4000, child: Text('flow')),
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      // maxScrollExtent = 4000 - viewport: the document is scrollable.
      expect(navigation.snapshot.showScrubber, isTrue);
      expect(navigation.snapshot.canSeek, isTrue);
      expect(navigation.snapshot.positionLabel, '42%');
      expect(navigation.snapshot.confirmedFraction, 0.0);
      expect(navigation.labelForFraction(0.5), '50%');

      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      expect(navigation.snapshot.confirmedFraction, closeTo(1.0, 1e-9));

      // Seek lands at the clamped fraction of the scroll extent.
      await navigation.seekToFraction(0.25);
      expect(
        controller.position.pixels,
        closeTo(controller.position.maxScrollExtent * 0.25, 1e-6),
      );
    });

    testWidgets('a screenful document keeps the scrubber hidden', (
      tester,
    ) async {
      final renderer = TextRendererStub()..loadState = ReaderLoadState.ready;
      final controller = AutoScrollController();
      final navigation = TextReaderNavigation(
        renderer: renderer,
        scrollController: controller,
        progressPercent: ValueNotifier<int>(0),
      );
      addTearDown(navigation.dispose);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomScrollView(
            controller: controller,
            slivers: <Widget>[
              SliverToBoxAdapter(
                child: SizedBox(height: 200, child: Text('short')),
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(navigation.snapshot.showScrubber, isFalse);
    });
  });

  group('Office navigation', () {
    test('DOCX pages project position and percent-style label', () {
      final renderer = OfficeRendererStub(document: stubEntry('doc.docx'))
        ..officeSourceReady = true
        ..currentPosition = 3
        ..positionCount = 8;
      final navigation = OfficeReaderNavigation(
        renderer,
        supportsScrubbing: true,
      );
      addTearDown(navigation.dispose);

      final snapshot = navigation.snapshot;
      expect(snapshot.kind, ReaderPositionKind.pages);
      expect(snapshot.showScrubber, isTrue);
      expect(snapshot.canSeek, isTrue);
      expect(snapshot.confirmedFraction, closeTo(2 / 7, 1e-9));
      expect(snapshot.currentPosition, 3);
      expect(snapshot.positionCount, 8);
      expect(snapshot.minimumSeekInterval, const Duration(milliseconds: 80));
      expect(navigation.labelForFraction(0.5), '5 / 8');
    });

    test('PPTX never exposes scrub commands', () {
      final renderer = OfficeRendererStub(document: stubEntry('deck.pptx'))
        ..officeSourceReady = true
        ..currentPosition = 2
        ..positionCount = 9;
      final navigation = OfficeReaderNavigation(
        renderer,
        supportsScrubbing: false,
      );
      addTearDown(navigation.dispose);

      final snapshot = navigation.snapshot;
      expect(snapshot.kind, ReaderPositionKind.slides);
      expect(snapshot.showScrubber, isFalse);
      expect(snapshot.canSeek, isFalse);
    });

    test('a two-position document stays hidden', () {
      final renderer = OfficeRendererStub(document: stubEntry('doc.docx'))
        ..officeSourceReady = true
        ..positionCount = 2;
      final navigation = OfficeReaderNavigation(
        renderer,
        supportsScrubbing: true,
      );
      addTearDown(navigation.dispose);
      expect(navigation.snapshot.showScrubber, isFalse);
    });

    test(
      'dispose detaches renderer listeners without closing the renderer',
      () async {
        final renderer = OfficeRendererStub(document: stubEntry('doc.docx'))
          ..officeSourceReady = true;
        final navigation = OfficeReaderNavigation(
          renderer,
          supportsScrubbing: true,
        );
        var notifications = 0;
        navigation.addListener(() => notifications++);
        navigation.dispose();
        navigation.dispose();
        renderer.notifyListeners();
        expect(notifications, 0);
        // The renderer itself must stay alive and usable.
        expect(renderer.positionCount, 0);
        renderer.dispose();
      },
    );
  });
}
