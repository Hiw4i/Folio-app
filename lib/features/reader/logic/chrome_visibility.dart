/// What the reading chrome should do after the latest scroll intent.
enum ChromeVisibilityCommand { stay, show, hide }

/// Pure accumulator turning user scroll deltas into chrome show/hide
/// commands.
///
/// A short intentional drag is required before the chrome changes direction:
/// the accumulator filters touch jitter, ballistic bounce-back, tiny reading
/// corrections and programmatic reveals (which never send drag deltas).
/// Same-direction intent accumulates across frames until it crosses
/// [threshold]; any contrary signal resets it.
class ChromeScrollIntentAccumulator {
  ChromeScrollIntentAccumulator({required this.threshold})
    : assert(threshold > 0);

  /// Drag distance, in logical pixels, required to flip the chrome.
  final double threshold;

  double _accumulated = 0;

  /// A preference change or an explicit chrome toggle must not complete a
  /// half-recorded scroll intent.
  void reset() {
    _accumulated = 0;
  }

  /// Records a drag of [delta] (positive scrolls down, toward hiding) while
  /// the chrome target is [visible]. [canHide] is false near the top of the
  /// document, where hiding the chrome would strand the reader without it.
  ChromeVisibilityCommand record(
    double delta, {
    required bool visible,
    required bool canHide,
  }) {
    assert(delta.isFinite, 'Scroll deltas must be finite');
    if (visible) {
      if (delta <= 0 || !canHide) {
        _accumulated = 0;
        return ChromeVisibilityCommand.stay;
      }
      _accumulated = (_accumulated + delta).clamp(0.0, threshold);
      if (_accumulated >= threshold) {
        _accumulated = 0;
        return ChromeVisibilityCommand.hide;
      }
      return ChromeVisibilityCommand.stay;
    }
    if (delta >= 0) {
      _accumulated = 0;
      return ChromeVisibilityCommand.stay;
    }
    _accumulated = (_accumulated + delta).clamp(-threshold, 0.0);
    if (_accumulated <= -threshold) {
      _accumulated = 0;
      return ChromeVisibilityCommand.show;
    }
    return ChromeVisibilityCommand.stay;
  }
}
