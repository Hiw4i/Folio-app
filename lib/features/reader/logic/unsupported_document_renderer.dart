import 'package:flutter/foundation.dart';

import '../../library/data/document_entry.dart';
import 'document_renderer_contract.dart';
import 'reader_search_state.dart';
import 'reader_state.dart';

class UnsupportedDocumentRenderer extends ChangeNotifier
    implements DocumentRenderer {
  UnsupportedDocumentRenderer(this.document);

  @override
  final DocumentEntry document;
  @override
  ReaderLoadState loadState = ReaderLoadState.loading;
  @override
  ReaderFailure? failure;
  @override
  String query = '';

  @override
  int get activeHitIndex => -1;
  @override
  ReaderSearchHit? get activeHit => null;
  @override
  int get hitCount => 0;
  @override
  bool get isSearching => false;

  @override
  ReaderSearchSnapshot get searchState => const ReaderSearchSnapshot(
    query: '',
    phase: ReaderSearchPhase.idle,
    textAvailability: ReaderTextAvailability.unsupported,
    hitCount: 0,
    activeHitIndex: -1,
  );

  @override
  Future<void> open() async {
    loadState = ReaderLoadState.failed;
    failure = ReaderFailure(
      kind: ReaderFailureKind.unsupportedFormat,
      title: '${document.format.extension.toUpperCase()} reader unavailable',
      message: 'This document renderer is not included in this build yet.',
    );
    notifyListeners();
  }

  @override
  Future<void> close() async {}
  @override
  Future<void> search(String query) async {}
  @override
  void showNextHit() {}
  @override
  void showPreviousHit() {}
}
