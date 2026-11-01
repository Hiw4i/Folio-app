import 'package:flutter/foundation.dart';

import '../../library/data/document_entry.dart';
import 'reader_search_state.dart';
import 'reader_state.dart';

abstract interface class DocumentRenderer implements Listenable {
  DocumentEntry get document;
  ReaderLoadState get loadState;
  ReaderFailure? get failure;
  String get query;
  bool get isSearching;
  int get hitCount;
  int get activeHitIndex;
  ReaderSearchHit? get activeHit;

  /// Immutable projection of the search state for shell consumers. Derived
  /// from the fields above on demand; never a second mutable copy.
  ReaderSearchSnapshot get searchState;

  Future<void> open();
  Future<void> close();
  Future<void> search(String query);
  void showNextHit();
  void showPreviousHit();
  void dispose();
}
