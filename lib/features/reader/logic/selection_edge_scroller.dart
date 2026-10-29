import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Snapshot of a scrollable's physical viewport and logical scroll extents.
class SelectionScrollTarget {
  const SelectionScrollTarget({
    required this.identity,
    required this.viewport,
    required this.pixels,
    required this.minExtent,
    required this.maxExtent,
    required this.jumpTo,
    this.axisDirection = AxisDirection.down,
  });

  final Object identity;
  final Rect viewport;
  final double pixels;
  final double minExtent;
  final double maxExtent;
  final AxisDirection axisDirection;
  final ValueChanged<double> jumpTo;
}

/// Frame-driven edge scrolling shared by text and transformed PDF viewports.
/// Speeds and pointer coordinates use logical screen pixels.
class SelectionEdgeScrollDriver {
  SelectionEdgeScrollDriver({
    required TickerProvider vsync,
    required SelectionScrollTarget? Function() target,
    required this._onScrolled,
  }) : _snapshot = target {
    _ticker = vsync.createTicker(_tick);
  }

  static const _edgeZone = 72.0;
  static const _minimumSpeed = 280.0;
  static const _maximumSpeed = 1000.0;
  static const _holdDelaySeconds = 0.9;
  static const _rampSeconds = 1.5;
  static const _maximumExtraSpeed = 0.6;
  static const _maximumFrameSeconds = 0.05;

  final SelectionScrollTarget? Function() _snapshot;
  final VoidCallback _onScrolled;
  late final Ticker _ticker;
  Offset? _globalPosition;
  Object? _activeIdentity;
  Duration? _lastElapsed;
  double _heldSeconds = 0;
  int _direction = 0;
  bool _disposed = false;

  bool get scrolling => !_disposed && _ticker.isActive;

  void update(Offset globalPosition) {
    if (_disposed) return;
    _globalPosition = globalPosition;
    final target = _target();
    if (target == null) {
      stop();
      return;
    }
    if (_direction != target.direction ||
        !identical(_activeIdentity, target.scroll.identity)) {
      _ticker.stop();
      _lastElapsed = null;
      _heldSeconds = 0;
      _direction = target.direction;
      _activeIdentity = target.scroll.identity;
    }
    if (!_ticker.isActive) _ticker.start();
  }

  void stop() {
    if (_disposed) return;
    _ticker.stop();
    _globalPosition = null;
    _activeIdentity = null;
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
    final scroll = _snapshot();
    if (point == null || !point.isFinite || scroll == null) return null;
    final bounds = scroll.viewport;
    if (!bounds.isFinite ||
        bounds.isEmpty ||
        !scroll.pixels.isFinite ||
        !scroll.minExtent.isFinite ||
        !scroll.maxExtent.isFinite ||
        scroll.minExtent >= scroll.maxExtent) {
      return null;
    }
    final vertical = axisDirectionToAxis(scroll.axisDirection) == Axis.vertical;
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
    final direction = axisDirectionIsReversed(scroll.axisDirection)
        ? -physicalDirection
        : physicalDirection;
    if ((direction < 0 && scroll.pixels <= scroll.minExtent) ||
        (direction > 0 && scroll.pixels >= scroll.maxExtent)) {
      return null;
    }
    return _EdgeTarget(scroll, direction, proximity);
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
        !identical(_activeIdentity, target.scroll.identity)) {
      _heldSeconds = 0;
      _direction = target.direction;
      _activeIdentity = target.scroll.identity;
      return;
    }
    final frameSeconds =
        (elapsed - previous).inMicroseconds / Duration.microsecondsPerSecond;
    if (frameSeconds <= 0) return;
    _heldSeconds += frameSeconds;
    final boundedSeconds = math.min(frameSeconds, _maximumFrameSeconds);
    final speed =
        _minimumSpeed + (_maximumSpeed - _minimumSpeed) * target.proximity;
    final distance =
        speed *
        (_holdIntegral(_heldSeconds) -
            _holdIntegral(_heldSeconds - boundedSeconds));
    final scroll = target.scroll;
    final next = (scroll.pixels + target.direction * distance).clamp(
      scroll.minExtent,
      scroll.maxExtent,
    );
    if (next == scroll.pixels) {
      stop();
      return;
    }
    scroll.jumpTo(next);
    if (_disposed) return;
    if (next == scroll.minExtent || next == scroll.maxExtent) stop();
    _onScrolled();
  }

  // Integrating the ramp keeps travel independent of display refresh cadence.
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

/// Adapter for ordinary Flutter scrollables. The original text-reader import
/// remains available for callers outside the reader implementation.
class SelectionEdgeScroller extends SelectionEdgeScrollDriver {
  SelectionEdgeScroller({
    required super.vsync,
    required ScrollController Function() scrollController,
    required Rect? Function() viewport,
    required super.onScrolled,
  }) : super(
         target: () {
           final positions = scrollController().positions;
           final bounds = viewport();
           if (positions.length != 1 || bounds == null) return null;
           final position = positions.single;
           if (!position.hasPixels || !position.hasContentDimensions) {
             return null;
           }
           return SelectionScrollTarget(
             identity: position,
             viewport: bounds,
             pixels: position.pixels,
             minExtent: position.minScrollExtent,
             maxExtent: position.maxScrollExtent,
             axisDirection: position.axisDirection,
             jumpTo: position.jumpTo,
           );
         },
       );
}

class _EdgeTarget {
  const _EdgeTarget(this.scroll, this.direction, this.proximity);
  final SelectionScrollTarget scroll;
  final int direction;
  final double proximity;
}
