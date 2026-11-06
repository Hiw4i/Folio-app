import 'package:flutter/widgets.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import '../../logic/reader_state.dart';
import '../../text/logic/text_document_renderer.dart';
import '../../text/widgets/text_reader_surface.dart';
import '../reader_loading_view.dart';
import '../reader_status_views.dart';
import 'reader_binding.dart';
import 'text_reader_navigation.dart';

/// Text binding: owns the UI-side scroll resources — the [AutoScrollController]
/// the document view and the scrub navigation share, and the percent
/// projection the indicator reads. TXT/Markdown scroll natively, so chrome
/// reactions ride scroll notifications, not drag callbacks.
final class TextReaderBinding implements ReaderBinding {
  TextReaderBinding(this.renderer) {
    _scrollController = AutoScrollController(
      axis: Axis.vertical,
      suggestedRowHeight: 3200,
    );
    _progressPercent = ValueNotifier<int>(0);
    _scrollController.addListener(_updateProgressPercent);
    navigation = TextReaderNavigation(
      renderer: renderer,
      scrollController: _scrollController,
      progressPercent: _progressPercent,
    );
  }

  @override
  final TextDocumentRenderer renderer;

  late final AutoScrollController _scrollController;
  late final ValueNotifier<int> _progressPercent;

  @override
  late final TextReaderNavigation navigation;

  @override
  ReaderInteractionPolicy get interactionPolicy =>
      const ReaderInteractionPolicy(scrollControlsChrome: true);

  @override
  bool get hasSurfaceOverlay => false;

  @override
  bool closeSurfaceOverlay() => false;

  @override
  Widget buildSurface(ReaderSurfaceCallbacks callbacks) {
    if (renderer.loadState == ReaderLoadState.loading) {
      return ReaderLoadingView(document: renderer.document);
    }
    final content = renderer.content;
    if (content == null || content.chunks.isEmpty) {
      return const ReaderStatusView(
        title: 'Nothing to display',
        message: 'This document has no readable content.',
      );
    }
    return TextReaderSurface(
      renderer: renderer,
      scrollController: _scrollController,
      onSelectionChanged: callbacks.onSelectionChanged,
    );
  }

  void _updateProgressPercent() {
    if (!_scrollController.hasClients) {
      return;
    }
    final extent = _scrollController.position.maxScrollExtent;
    final next = extent <= 0
        ? 0
        : (_scrollController.offset / extent * 100).round().clamp(0, 100);
    if (next != _progressPercent.value) {
      _progressPercent.value = next;
    }
  }

  @override
  void dispose() {
    navigation.dispose();
    _scrollController
      ..removeListener(_updateProgressPercent)
      ..dispose();
    _progressPercent.dispose();
  }
}
