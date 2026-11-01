import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../../../../shared/diagnostics/app_log.dart';
import 'reader_navigation.dart';

/// Scrub-gesture state and seek dispatching for the reader scrubber.
///
/// Owns exactly the two things widgets must not duplicate: the finger
/// preview (the knob follows it every frame; the engine never confirms it)
/// and the dispatch schedule — at most one seek per frame, additionally
/// spaced by [ReaderNavigationSnapshot.minimumSeekInterval] for heavy
/// formats, with the freshest target always winning:
///
/// * the first request of a gesture is immediate, so the document starts
///   moving with the finger;
/// * a drag inside the throttle window parks the value as a trailing seek;
/// * a later drag stores a newer pending target, and ending the gesture
///   lands on the newer pending (falling back to the trailing one);
/// * cancel/dispose leave no timers or frame callbacks behind.
final class ReaderScrubController with ChangeNotifier {
  ReaderScrubController(this._navigation, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final ReaderNavigation _navigation;
  final DateTime Function() _now;

  /// Finger fraction while scrubbing. A [ValueNotifier] so 120 Hz drag
  /// updates repaint only the knob/pill, never the whole strip.
  final ValueNotifier<double> preview = ValueNotifier<double>(0);

  bool _isScrubbing = false;
  bool _frameScheduled = false;
  double? _pendingTarget;
  double? _trailingTarget;
  Timer? _throttleTimer;
  DateTime _lastDispatchAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isScrubbing => _isScrubbing;

  /// Finger position in `[0, 1]`, or `null` between gestures — preview, not
  /// an engine-confirmed fraction.
  double? get previewFraction => _isScrubbing ? preview.value : null;

  void begin(double fraction) {
    if (_isScrubbing) {
      return;
    }
    _isScrubbing = true;
    _trailingTarget = null;
    _throttleTimer?.cancel();
    _throttleTimer = null;
    final target = normalizeScrubFraction(fraction) ?? 0.0;
    preview.value = target;
    // First jump is immediate so the document starts moving with the finger.
    _lastDispatchAt = _now();
    _dispatch(target);
    notifyListeners();
  }

  void update(double fraction) {
    if (!_isScrubbing) {
      begin(fraction);
      return;
    }
    final target = normalizeScrubFraction(fraction);
    if (target == null) {
      return;
    }
    preview.value = target;
    _pendingTarget = target;
    _scheduleFlush();
  }

  /// Ends the gesture and lands the document on the latest finger position.
  /// The drag-cancel path uses the same landing on purpose.
  void end() {
    if (!_isScrubbing) {
      return;
    }
    _throttleTimer?.cancel();
    _throttleTimer = null;
    // The pending target is newer than a parked trailing seek: the finger
    // moved after the last throttle flush, so it is the position to land on.
    final target = _pendingTarget ?? _trailingTarget;
    _pendingTarget = null;
    _trailingTarget = null;
    if (target != null) {
      _lastDispatchAt = _now();
      _dispatch(target);
    }
    _isScrubbing = false;
    notifyListeners();
  }

  /// Gesture cancelled by the framework: same exact landing as [end].
  void cancel() => end();

  void _scheduleFlush() {
    if (_frameScheduled) {
      return;
    }
    _frameScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _frameScheduled = false;
      if (_isScrubbing) {
        _flush();
      }
    });
  }

  void _flush() {
    final target = _pendingTarget;
    if (target == null) {
      return;
    }
    _pendingTarget = null;
    final interval = _navigation.snapshot.minimumSeekInterval;
    final sinceLast = _now().difference(_lastDispatchAt);
    if (sinceLast < interval) {
      // Too soon after the previous dispatch: remember the latest position
      // and deliver it on the throttle boundary. The knob already follows
      // the finger via [preview], so the spacing is invisible.
      _trailingTarget = target;
      _throttleTimer?.cancel();
      _throttleTimer = Timer(interval - sinceLast, () {
        _throttleTimer = null;
        final trailing = _trailingTarget;
        _trailingTarget = null;
        if (trailing == null || !_isScrubbing) {
          return;
        }
        _lastDispatchAt = _now();
        _dispatch(trailing);
      });
      return;
    }
    _lastDispatchAt = _now();
    _dispatch(target);
  }

  void _dispatch(double target) {
    try {
      unawaited(_navigation.seekToFraction(target));
    } catch (error, stack) {
      AppLog.w('Folio scrub seek failed', error, stack);
    }
  }

  @override
  void dispose() {
    if (_isScrubbing || _throttleTimer != null) {
      // A disposed controller must not fire its parked trailing seek.
      _isScrubbing = false;
    }
    _throttleTimer?.cancel();
    _throttleTimer = null;
    preview.dispose();
    super.dispose();
  }
}
