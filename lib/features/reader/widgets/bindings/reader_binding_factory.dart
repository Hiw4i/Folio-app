import 'package:flutter/widgets.dart';

import '../../../library/data/document_entry.dart';
import '../../logic/document_renderer.dart';
import '../../logic/reader_navigation.dart';
import '../reader_loading_view.dart';
import 'office_reader_binding.dart';
import 'pdf_reader_binding.dart';
import 'reader_binding.dart';
import 'text_reader_binding.dart';

/// The single place the shell chooses a UI adapter from a renderer type.
/// Format knowledge lives here and in the format surfaces — nowhere else.
ReaderBinding createReaderBinding(DocumentRenderer renderer) {
  return switch (renderer) {
    PdfDocumentRenderer() => PdfReaderBinding(renderer),
    OfficeDocumentRendererBase() => OfficeReaderBinding(
      renderer,
      supportsScrubbing: renderer is! PowerPointDocumentRenderer,
    ),
    TextDocumentRenderer() => TextReaderBinding(renderer),
    UnsupportedDocumentRenderer() => UnsupportedReaderBinding(renderer),
    // An unknown renderer reaching the shell is a programming error, not a
    // product state: fail fast instead of guessing an adapter.
    _ => throw StateError('No reader binding for ${renderer.runtimeType}'),
  };
}

/// Safe adapter for renderers without a positional model or surface: no seek
/// commands, no scrubber, and a plain loading surface — the shell's failure
/// path takes over as soon as the renderer reports its unsupported state.
final class UnsupportedReaderBinding implements ReaderBinding {
  UnsupportedReaderBinding(this.renderer);

  @override
  final UnsupportedDocumentRenderer renderer;

  // One instance per binding: the contract forbids recreating owned
  // navigation resources on repeated access.
  late final _UnsupportedReaderNavigation _navigation =
      _UnsupportedReaderNavigation(renderer);

  @override
  ReaderNavigation get navigation => _navigation;

  @override
  ReaderInteractionPolicy get interactionPolicy =>
      const ReaderInteractionPolicy(scrollControlsChrome: false);

  @override
  Widget buildSurface(ReaderSurfaceCallbacks callbacks) {
    return ReaderLoadingView(document: renderer.document);
  }

  @override
  void dispose() {}
}

/// No-op navigation for the unsupported fallback: nothing is seekable and
/// nothing is measured.
final class _UnsupportedReaderNavigation implements ReaderNavigation {
  const _UnsupportedReaderNavigation(this.renderer);

  final UnsupportedDocumentRenderer renderer;

  @override
  ReaderNavigationSnapshot get snapshot => ReaderNavigationSnapshot(
    canSeek: false,
    showScrubber: false,
    positionLabel: renderer.document.format.extension.toUpperCase(),
    kind: null,
  );

  @override
  String labelForFraction(double fraction) => snapshot.positionLabel;

  @override
  Future<void> seekToFraction(double fraction) => Future<void>.value();

  @override
  void revalidate() {}

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  void dispose() {}
}
