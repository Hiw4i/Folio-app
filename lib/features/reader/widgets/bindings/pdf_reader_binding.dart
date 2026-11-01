import 'package:flutter/widgets.dart';

import '../../pdf/logic/pdf_document_renderer.dart';
import '../../pdf/widgets/pdf_document_view.dart';
import 'pdf_reader_navigation.dart';
import 'reader_binding.dart';

/// PDF binding: projects the continuous viewer fraction through
/// [PdfReaderNavigation] and builds the real PDF surface.
///
/// Selection state stays inside the PDF surface for now; the shell keeps
/// learning about it through its own pointer tracking until the selection
/// normalization lands here.
final class PdfReaderBinding implements ReaderBinding {
  PdfReaderBinding(this.renderer) : navigation = PdfReaderNavigation(renderer);

  @override
  final PdfDocumentRenderer renderer;

  @override
  final PdfReaderNavigation navigation;

  @override
  ReaderInteractionPolicy get interactionPolicy =>
      const ReaderInteractionPolicy(scrollControlsChrome: true);

  @override
  Widget buildSurface(ReaderSurfaceCallbacks callbacks) {
    return PdfDocumentView(
      renderer: renderer,
      onContentTap: callbacks.onContentTap,
      onVerticalReadingGesture: (delta) => callbacks.onReadingDrag(delta, true),
    );
  }

  @override
  void dispose() {
    navigation.dispose();
  }
}
