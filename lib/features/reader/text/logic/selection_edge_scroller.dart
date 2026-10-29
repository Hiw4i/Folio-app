import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Scrolls a selection held near a physical viewport edge, including when the
/// pointer stops moving. Coordinates and speeds are in logical pixels.
///
/// The owner supplies its current controller and global viewport on each frame,
/// and must call [stop] when a selection drag ends. [onScrolled] runs after a
/// real offset change; selection events can then be replayed after layout.
class SelectionEdgeScroller {
  SelectionEdgeScroller({
    required TickerProvider vsync,
    required this._scrollController,
    required this._viewport,
    required this._onScrolled,
  }) {
    _ticker = vsync.createTicker(_tick);
  }

  static const _edgeZone = 72.0;
  static const _minimumSpeed = 280.0;
  static const _maximumSpeed = 1000.0;
  static const _holdDelaySeconds = 0.9;
  static const _rampSeconds = 1.5;
  static const _maximumExtraSpeed = 0.6;
  static const _maximumFrameSeconds = 0.05;

  final ScrollController Function() _scrollController;
  final Rect? Function() _viewport;
  final VoidCallback _onScrolled;
  late final Ticker _ticker;
  Offset? _globalPosition;
  ScrollPosition? _activePosition;
  Duration? _lastElapsed;
  double _heldSeconds = 0;
  int _direction = 0;
  bool _disposed = false;

  bool get scrolling => !_disposed && _ticker.isActive;

  /// Updates the held pointer without restarting its dwell in the same edge.
  void update(Offset globalPosition) {
    if (_disposed) return;
    _globalPosition = globalPosition;
    final target = _target();
    if (target == null) {
      stop();
      return;
    }
    if (_direction != target.direction ||
        !identical(_activePosition, target.position)) {
      _ticker.stop();
      _lastElapsed = null;
      _heldSeconds = 0;
      _direction = target.direction;
      _activePosition = target.position;
    }
    if (!_ticker.isActive) _ticker.start();
  }

  /// Releases pending frames and resets the dwell for the next drag.
  void stop() {
    if (_disposed) return;
    _ticker.stop();
    _globalPosition = null;
    _activePosition = null;
    _lastElapsed = null;
    _heldSeconds = 0;
    _direction = 0;
  }

  void dispose() {
    if (_disposed) return;
    stop();
    _disposed = true;
    _ticker.dispose();
  }

  _EdgeTarget? _target() {
    final point = _globalPosition;
    final bounds = _viewport();
    if (point == null ||
        !point.isFinite ||
        bounds == null ||
        !bounds.isFinite ||
        bounds.isEmpty) {
      return null;
    }
    final positions = _scrollController().positions;
    if (positions.length != 1) return null;
    final position = positions.single;
    if (!position.hasPixels ||
        !position.hasContentDimensions ||
        !position.pixels.isFinite ||
        !position.minScrollExtent.isFinite ||
        !position.maxScrollExtent.isFinite ||
        position.minScrollExtent >= position.maxScrollExtent) {
      return null;
    }

    final vertical =
        axisDirectionToAxis(position.axisDirection) == Axis.vertical;
    final leading = vertical ? bounds.top : bounds.left;
    final trailing = vertical ? bounds.bottom : bounds.right;
    final coordinate = vertical ? point.dy : point.dx;
    final zone = math.min(_edgeZone, (trailing - leading) / 2);
    final leadingDistance = coordinate - leading;
    final trailingDistance = trailing - coordinate;
    final int physicalDirection;
    final double proximity;
    if (leadingDistance < zone && leadingDistance <= trailingDistance) {
      physicalDirection = -1;
      proximity = (1 - leadingDistance / zone).clamp(0.0, 1.0);
    } else if (trailingDistance < zone) {
      physicalDirection = 1;
      proximity = (1 - trailingDistance / zone).clamp(0.0, 1.0);
    } else {
      return null;
    }
    final direction = axisDirectionIsReversed(position.axisDirection)
        ? -physicalDirection
        : physicalDirection;
    if ((direction < 0 && position.pixels <= position.minScrollExtent) ||
        (direction > 0 && position.pixels >= position.maxScrollExtent)) {
      return null;
    }
    return _EdgeTarget(position, direction, proximity);
  }

  void _tick(Duration elapsed) {
    if (_disposed) return;
    final target = _target();
    if (target == null) {
      stop();
      return;
    }
    final previous = _lastElapsed;
    _lastElapsed = elapsed;
    if (previous == null ||
        _direction != target.direction ||
        !identical(_activePosition, target.position)) {
      _heldSeconds = 0;
      _direction = target.direction;
      _activePosition = target.position;
      return;
    }
    final frameSeconds =
        (elapsed - previous).inMicroseconds / Duration.microsecondsPerSecond;
    if (frameSeconds <= 0) return;
    _heldSeconds += frameSeconds;
    // A paused/backgrounded frame must not jump through a large text range.
    final boundedSeconds = math.min(frameSeconds, _maximumFrameSeconds);
    final speed =
        _minimumSpeed + (_maximumSpeed - _minimumSpeed) * target.proximity;
    final distance =
        speed *
        (_holdIntegral(_heldSeconds) -
            _holdIntegral(_heldSeconds - boundedSeconds));
    final position = target.position;
    final next = (position.pixels + target.direction * distance).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (next == position.pixels) {
      stop();
      return;
    }
    position.jumpTo(next);
    if (_disposed) return;
    if (next == position.minScrollExtent || next == position.maxScrollExtent) {
      stop();
    }
    _onScrolled();
  }

  // Integral of a smoothstep speed ramp: independent of the display cadence.
  static double _holdIntegral(double seconds) {
    final progress = ((seconds - _holdDelaySeconds) / _rampSeconds).clamp(
      0.0,
      1.0,
    );
    final squared = progress * progress;
    final integratedRamp = squared * progress - squared * squared / 2;
    final beyondRamp = math.max(
      0.0,
      seconds - _holdDelaySeconds - _rampSeconds,
    );
    return seconds +
        _maximumExtraSpeed * (_rampSeconds * integratedRamp + beyondRamp);
  }
}

class _EdgeTarget {
  const _EdgeTarget(this.position, this.direction, this.proximity);

  final ScrollPosition position;
  final int direction;
  final double proximity;
}
