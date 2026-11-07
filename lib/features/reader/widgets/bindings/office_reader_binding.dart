import 'package:flutter/widgets.dart';

import '../../office/logic/office_document_renderer_base.dart';
import '../../office/widgets/office_staged_view.dart';
import '../../powerpoint/logic/powerpoint_document_renderer.dart';
import '../../powerpoint/widgets/powerpoint_document_view.dart';
import '../../word/logic/word_document_renderer.dart';
import '../../word/widgets/word_document_view.dart';
import '../reader_loading_view.dart';
import 'office_reader_navigation.dart';
import 'reader_binding.dart';

/// Office binding: one projection for DOCX and PPTX with the scrubbing rule
/// decided at the composition root — DOCX pages scrub, PPTX slides do not.
final class OfficeReaderBinding implements ReaderBinding {
  OfficeReaderBinding(this.renderer, {required bool supportsScrubbing})
    : navigation = OfficeReaderNavigation(
        renderer,
        supportsScrubbing: supportsScrubbing,
      ),
      interactionPolicy = ReaderInteractionPolicy(
        scrollControlsChrome: renderer is! PowerPointDocumentRenderer,
      );

  @override
  final OfficeDocumentRendererBase renderer;

  @override
  final OfficeReaderNavigation navigation;

  @override
  final ReaderInteractionPolicy interactionPolicy;

  @override
  bool get hasSurfaceOverlay => renderer.slideOverviewOpen;

  @override
  bool closeSurfaceOverlay() {
    if (!renderer.slideOverviewOpen) {
      return false;
    }
    renderer.closeOverview();
    return true;
  }

  @override
  Widget buildSurface(ReaderSurfaceCallbacks callbacks) {
    if (!renderer.sourceReady) {
      return ReaderLoadingView(document: renderer.document);
    }
    final Widget view = renderer is WordDocumentRenderer
        ? WordDocumentView(
            renderer: renderer as WordDocumentRenderer,
            onContentTap: callbacks.onContentTap,
            onReadingGesture: (delta) => callbacks.onReadingDrag(delta, true),
          )
        : PowerPointDocumentView(
            renderer: renderer as PowerPointDocumentRenderer,
            onContentTap: callbacks.onContentTap,
          );
    return OfficeStagedView(renderer: renderer, view: view);
  }

  @override
  void dispose() {
    navigation.dispose();
  }
}
