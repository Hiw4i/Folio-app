import 'package:flutter/foundation.dart';

import 'reader_state.dart';

/// Search phase as the reader shell observes it. `waitingForSource` means a
/// non-empty query exists while the document source is not ready yet — it is
/// deliberately distinct from `complete` so early queries can never be shown
/// as a final "no results".
enum ReaderSearchPhase { idle, waitingForSource, searching, complete, failed }

/// Whether the document carries a searchable text layer at all.
///
/// `unknown` is not `absent`: availability can be confirmed only after the
/// document's text layer has actually been examined.
enum ReaderTextAvailability { unknown, present, absent, unsupported }

/// Immutable projection of one renderer's search state for shell consumers.
///
/// [failure] carries an observed search error (a command/channel failure),
/// never a zero-result outcome; those are expressed through [hitCount].
@immutable
class ReaderSearchSnapshot {
  const ReaderSearchSnapshot({
    required this.query,
    required this.phase,
    required this.textAvailability,
    required this.hitCount,
    required this.activeHitIndex,
    this.failure,
  });

  final String query;
  final ReaderSearchPhase phase;
  final ReaderTextAvailability textAvailability;

  /// Total matches; `0` is a legitimate result over a present text layer.
  final int hitCount;

  /// Index of the active match, or `-1` when nothing is active.
  final int activeHitIndex;

  /// The observed search error, if the last search attempt failed.
  final ReaderFailure? failure;

  @override
  bool operator ==(Object other) {
    return other is ReaderSearchSnapshot &&
        other.query == query &&
        other.phase == phase &&
        other.textAvailability == textAvailability &&
        other.hitCount == hitCount &&
        other.activeHitIndex == activeHitIndex &&
        other.failure == failure;
  }

  @override
  int get hashCode => Object.hash(
    query,
    phase,
    textAvailability,
    hitCount,
    activeHitIndex,
    failure,
  );
}
