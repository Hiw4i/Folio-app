import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/reader/logic/reader_navigation.dart';
import 'package:folio/features/reader/office/widgets/office_staged_view.dart';
import 'package:folio/features/reader/pdf/widgets/pdf_document_view.dart';
import 'package:folio/features/reader/widgets/reader_loading_view.dart';
import 'package:folio/features/reader/powerpoint/widgets/powerpoint_document_view.dart';
import 'package:folio/features/reader/widgets/bindings/office_reader_binding.dart';
import 'package:folio/features/reader/widgets/bindings/pdf_reader_binding.dart';
import 'package:folio/features/reader/widgets/bindings/reader_binding.dart';
import 'package:folio/features/reader/word/widgets/word_document_view.dart';

import '../../support/reader_stubs.dart';

void main() {
  group('PDF binding', () {
    test('projects navigation and builds the real PDF surface', () {
      final renderer = PdfRendererStub()..pdfSourceReady = true;
      final binding = PdfReaderBinding(renderer);
      addTearDown(binding.dispose);

      expect(binding.renderer, same(renderer));
      expect(binding.navigation.snapshot.canSeek, isTrue);
      expect(binding.interactionPolicy.scrollControlsChrome, isTrue);

      final taps = <int>[];
      final drags = <double>[];
      final surface = binding.buildSurface(
        ReaderSurfaceCallbacks(
          onContentTap: () => taps.add(1),
          onReadingDrag: (delta, canHide) {
            expect(canHide, isTrue);
            drags.add(delta);
          },
          onSelectionChanged: (_) {},
        ),
      );
      // The pdf branch wraps the viewer in the stable fade wrapper.
      expect(surface, isA<ReaderContentFadeIn>());
      expect(
        (surface as ReaderContentFadeIn).child,
        isA<PdfDocumentView>(),
      );
    });
  });

  group('Office binding', () {
    testWidgets('DOCX scrubs, scrolls chrome and stages its surface', (
      tester,
    ) async {
      final renderer = WordRendererStub(document: stubEntry('doc.docx'));
      addTearDown(renderer.dispose);
      await renderer.open();
      final binding = OfficeReaderBinding(renderer, supportsScrubbing: true);

      expect(binding.interactionPolicy.scrollControlsChrome, isTrue);
      expect(binding.navigation.snapshot.kind, ReaderPositionKind.pages);

      // No session attached to a view yet → the binding shows the loader
      // instead of the staged surface.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: binding.buildSurface(
            const ReaderSurfaceCallbacks(
              onContentTap: _noop,
              onReadingDrag: _noopDrag,
              onSelectionChanged: _noopSelection,
            ),
          ),
        ),
      );
      expect(find.byType(OfficeStagedView), findsNothing);

      final view = RecordingOfficeView();
      renderer.attachView(view, renderer.session!.id);
      renderer.handleViewEvent(<Object?, Object?>{
        'type': 'ready',
        'count': 4,
        'hasText': true,
      });
      // The stub's sourceReady mirrors the session being attachable.
      renderer.officeSourceReady = true;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: binding.buildSurface(
            const ReaderSurfaceCallbacks(
              onContentTap: _noop,
              onReadingDrag: _noopDrag,
              onSelectionChanged: _noopSelection,
            ),
          ),
        ),
      );
      expect(find.byType(OfficeStagedView), findsOneWidget);
      expect(find.byType(WordDocumentView), findsOneWidget);
      binding.dispose();
    });

    testWidgets('PPTX never scrubs and never scrolls the chrome', (tester) async {
      final renderer = PowerPointRendererStub(document: stubEntry('deck.pptx'));
      addTearDown(renderer.dispose);
      await renderer.open();
      final binding = OfficeReaderBinding(renderer, supportsScrubbing: false);

      expect(binding.interactionPolicy.scrollControlsChrome, isFalse);
      expect(binding.navigation.snapshot.canSeek, isFalse);
      expect(binding.navigation.snapshot.showScrubber, isFalse);
      expect(binding.navigation.snapshot.kind, ReaderPositionKind.slides);

      renderer.handleViewEvent(<Object?, Object?>{
        'type': 'ready',
        'count': 3,
        'hasText': true,
      });
      renderer.officeSourceReady = true;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: binding.buildSurface(
            const ReaderSurfaceCallbacks(
              onContentTap: _noop,
              onReadingDrag: _noopDrag,
              onSelectionChanged: _noopSelection,
            ),
          ),
        ),
      );
      expect(find.byType(PowerPointDocumentView), findsOneWidget);
      binding.dispose();
    });
  });
}

void _noop() {}
void _noopDrag(double delta, bool canHide) {}
void _noopSelection(bool active) {}
