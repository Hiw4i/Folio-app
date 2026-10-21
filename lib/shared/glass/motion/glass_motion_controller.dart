import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../core/glass_tokens.dart';
import '../core/liquid_motion_controller.dart';

enum GlassInteractionState { idle, pressed, dragging, opening, open, closing }

enum GlassPointerTarget { none, main, cancel }

class GlassMotionController extends LiquidMotionController {
  /// When false, the controller never morphs: tap/drag drive only
  /// press/displacement like a collapsed menu button, and a tap never calls
  /// [requestOpen]. Lets plain buttons share literally the same interaction
  /// code path as the morphing menu reference.
  GlassMotionController({
    super.vsync,
    MotionTokens? tokens,
    this.morphEnabled = true,
  }) : _tokens = tokens ?? const MotionTokens.standard();

  final bool morphEnabled;
  bool _liquidMotionEnabled = true;

  bool get liquidMotionEnabled => _liquidMotionEnabled;
  MotionTokens _tokens;
  bool _wantsOpen = false;
  bool _pointerDown = false;
  bool _dragExceeded = false;
  bool _collapseImpulseArmed = false;
  bool _openingImpulseArmed = false;
  GlassPointerTarget _activeTarget = GlassPointerTarget.none;
  GlassPointerTarget _materialTarget = GlassPointerTarget.none;
  Offset _pointerStart = Offset.zero;
  Offset _lastPointer = Offset.zero;
  Duration _lastPointerTime = Duration.zero;
  // Seconds since the last pointer event. The release-fling velocity is
  // event-driven (never decays by itself), so the clarity signal gates it by
  // recency: steady motion reduces blur, a stale fling lets it recover.
  double _idleAfterPointer = 1e9;
  Offset _dragTarget = Offset.zero;
  Offset _lightTarget = Offset.zero;

  GlassInteractionState state = GlassInteractionState.idle;
  double morph = 0;
  double morphVelocity = 0;
  double separation = 0;
  double separationVelocity = 0;
  double press = 0;
  double pressVelocity = 0;
  double submitEnergy = 0;
  double submitVelocity = 0;
  double settleWobble = 0;
  double settleWobbleVelocity = 0;
  Offset displacement = Offset.zero;
  Offset displacementVelocity = Offset.zero;
  Offset pointerVelocity = Offset.zero;
  Offset lightPosition = Offset.zero;

  bool get wantsOpen => _wantsOpen;
  bool get isOpen => state == GlassInteractionState.open;
  bool get isPointerDown => _pointerDown;
  GlassPointerTarget get activeTarget => _activeTarget;
  GlassPointerTarget get materialTarget => _materialTarget;
  MotionTokens get tokens => _tokens;

  void _wake() {
    if (_liquidMotionEnabled) {
      wake();
    } else {
      _settleWithoutMotion();
    }
  }

  void setLiquidMotionEnabled(bool enabled) {
    if (_liquidMotionEnabled == enabled) {
      return;
    }
    _liquidMotionEnabled = enabled;
    if (!enabled) {
      stopSimulation();
      _settleWithoutMotion();
    } else {
      _wake();
    }
    notifyListeners();
  }

  void _settleWithoutMotion() {
    morph = _wantsOpen ? 1 : 0;
    separation = _wantsOpen ? 1 : 0;
    morphVelocity = separationVelocity = 0;
    press = pressVelocity = 0;
    submitEnergy = submitVelocity = 0;
    settleWobble = settleWobbleVelocity = 0;
    displacement = displacementVelocity = pointerVelocity = Offset.zero;
    _dragTarget = Offset.zero;
    if (!_pointerDown) {
      _materialTarget = GlassPointerTarget.none;
    }
    lightPosition = _lightTarget;
    backdropScale = 1;
    _openingImpulseArmed = _collapseImpulseArmed = false;
    state = _wantsOpen
        ? GlassInteractionState.open
        : _pointerDown
        ? GlassInteractionState.pressed
        : GlassInteractionState.idle;
  }

  @override
  bool get isAtRest {
    if (!_liquidMotionEnabled) {
      return true;
    }
    if (_pointerDown) {
      return false;
    }
    final parked = _wantsOpen
        ? state == GlassInteractionState.open
        : state == GlassInteractionState.idle;
    if (!parked) {
      return false;
    }
    if (press > 0.01 || submitEnergy > 0.005) {
      return false;
    }
    if (displacement.distance > 0.08 || displacementVelocity.distance > 0.8) {
      return false;
    }
    if ((lightPosition - _lightTarget).distance > 0.05) {
      return false;
    }
    // Keep the ticker alive until the backdrop blur is fully restored,
    // otherwise it would freeze mid-value (visible). The band matches the
    // snap band, so this gate clears no later than the legacy ones.
    if ((backdropScale - 1.0).abs() > LiquidBackdropAdapt.settleBand) {
      return false;
    }
    return true;
  }

  void setReducedMotion(bool reduced) {
    final next = reduced
        ? const MotionTokens.reduced()
        : const MotionTokens.standard();
    if (next.maxDrag == _tokens.maxDrag) {
      return;
    }
    _tokens = next;
    displacement = LiquidSpring.limitOffset(displacement, _tokens.maxDrag);
    _wake();
    notifyListeners();
  }

  void beginPointer({
    required Offset position,
    required Duration timestamp,
    required GlassPointerTarget target,
  }) {
    if (_pointerDown || target == GlassPointerTarget.none) {
      return;
    }
    _pointerDown = true;
    _dragExceeded = false;
    _idleAfterPointer = 0;
    _activeTarget = target;
    _materialTarget = target;
    _pointerStart = position;
    _lastPointer = position;
    _lastPointerTime = timestamp;
    _lightTarget = position;
    pointerVelocity = Offset.zero;
    if (!_wantsOpen && morph < 0.08 && target == GlassPointerTarget.main) {
      state = GlassInteractionState.pressed;
    }
    _wake();
    notifyListeners();
  }

  void movePointer({required Offset position, required Duration timestamp}) {
    _lightTarget = position;
    _idleAfterPointer = 0;
    if (!_pointerDown) {
      notifyListeners();
      return;
    }
    final elapsedMicros = (timestamp - _lastPointerTime).inMicroseconds.clamp(
      1000,
      100000,
    );
    final dt = elapsedMicros / Duration.microsecondsPerSecond;
    final rawVelocity = (position - _lastPointer) / dt;
    pointerVelocity = Offset.lerp(pointerVelocity, rawVelocity, 0.38)!;
    _lastPointer = position;
    _lastPointerTime = timestamp;

    final travel = position - _pointerStart;
    if (travel.distance > _tokens.tapSlop) {
      _dragExceeded = true;
      if (!_wantsOpen && _activeTarget == GlassPointerTarget.main) {
        state = GlassInteractionState.dragging;
      }
    }
    if (_dragExceeded && _activeTarget == GlassPointerTarget.main) {
      _dragTarget = LiquidSpring.limitOffset(
        travel * _tokens.dragGain,
        _tokens.maxDrag,
      );
    } else if (_dragExceeded && _activeTarget == GlassPointerTarget.cancel) {
      _dragTarget = LiquidSpring.limitOffset(travel * 0.32, 12);
    }
    _wake();
    notifyListeners();
  }

  void updateHover(Offset position) {
    if ((_lightTarget - position).distanceSquared < 0.01) {
      return;
    }
    _lightTarget = position;
    if (!_liquidMotionEnabled) {
      lightPosition = position;
      return;
    }
    _wake();
  }

  void endPointer({
    required Offset position,
    required Duration timestamp,
    bool openOnTap = true,
  }) {
    if (!_pointerDown) {
      return;
    }
    movePointer(position: position, timestamp: timestamp);
    final wasTap = !_dragExceeded;
    final target = _activeTarget;
    _pointerDown = false;
    _activeTarget = GlassPointerTarget.none;
    _dragTarget = Offset.zero;
    displacementVelocity += pointerVelocity * _tokens.velocityGain;

    if (wasTap && target == GlassPointerTarget.cancel && separation > 0.82) {
      requestClose();
    } else if (wasTap &&
        target == GlassPointerTarget.main &&
        morphEnabled &&
        openOnTap) {
      if (!_wantsOpen || state == GlassInteractionState.closing) {
        requestOpen();
      }
    } else if (!_wantsOpen) {
      state = GlassInteractionState.idle;
    }
    _wake();
    notifyListeners();
  }

  void cancelPointer() {
    if (!_pointerDown) {
      return;
    }
    _pointerDown = false;
    _dragExceeded = true;
    _activeTarget = GlassPointerTarget.none;
    _dragTarget = Offset.zero;
    if (!_wantsOpen && morph < 0.08) {
      state = GlassInteractionState.idle;
    }
    _wake();
    notifyListeners();
  }

  void requestOpen() {
    _openingImpulseArmed = morph < 0.94 || separation < 0.92;
    _wantsOpen = true;
    _collapseImpulseArmed = false;
    state = GlassInteractionState.opening;
    _wake();
    notifyListeners();
  }

  void requestClose() {
    _wantsOpen = false;
    _openingImpulseArmed = false;
    _collapseImpulseArmed = morph > 0.18;
    state = GlassInteractionState.closing;
    _wake();
    notifyListeners();
  }

  void submit() {
    if (morph < 0.78) {
      return;
    }
    submitEnergy = 1;
    submitVelocity = 0;
    _wake();
    notifyListeners();
  }

  @override
  void integrate(double dt) {
    if (!_liquidMotionEnabled) {
      return;
    }
    final previousMorph = morph;
    final previousSeparation = separation;
    final morphTarget = _wantsOpen
        ? 1.0
        : separation < 0.30
        ? 0.0
        : 1.0;
    final separationTarget = _wantsOpen && morph > 0.28 ? 1.0 : 0.0;

    final nextMorph = LiquidSpring.scalar(
      position: morph,
      velocity: morphVelocity,
      target: morphTarget,
      spring: _tokens.morph,
      dt: dt,
    );
    morph = nextMorph.$1;
    morphVelocity = nextMorph.$2;
    final nextSeparation = LiquidSpring.scalar(
      position: separation,
      velocity: separationVelocity,
      target: separationTarget,
      spring: _tokens.separation,
      dt: dt,
    );
    separation = nextSeparation.$1;
    separationVelocity = nextSeparation.$2;
    if (_wantsOpen &&
        _openingImpulseArmed &&
        previousSeparation < 0.92 &&
        separation >= 0.92 &&
        morph > 0.90) {
      settleWobbleVelocity += _tokens.maxDrag > 10 ? 132 : 20;
      _openingImpulseArmed = false;
    }
    final nextPress = LiquidSpring.scalar(
      position: press,
      velocity: pressVelocity,
      target: _pointerDown ? 1 : 0,
      spring: _tokens.press,
      dt: dt,
    );
    press = nextPress.$1;
    pressVelocity = nextPress.$2;
    final nextSubmit = LiquidSpring.scalar(
      position: submitEnergy,
      velocity: submitVelocity,
      target: 0,
      spring: const SpringDescription(mass: 1, stiffness: 250, damping: 19),
      dt: dt,
    );
    submitEnergy = nextSubmit.$1;
    submitVelocity = nextSubmit.$2;
    if (!_wantsOpen &&
        _collapseImpulseArmed &&
        previousMorph > 0.16 &&
        morph <= 0.16 &&
        separation < 0.10) {
      settleWobbleVelocity += _tokens.maxDrag > 10 ? 136 : 22;
      _collapseImpulseArmed = false;
    }
    final nextSettleWobble = LiquidSpring.scalar(
      position: settleWobble,
      velocity: settleWobbleVelocity,
      target: 0,
      spring: const SpringDescription(mass: 1, stiffness: 250, damping: 9.6),
      dt: dt,
    );
    settleWobble = nextSettleWobble.$1.clamp(-10.5, 10.5);
    settleWobbleVelocity = nextSettleWobble.$2;
    final nextDisplacement = LiquidSpring.offset(
      position: displacement,
      velocity: displacementVelocity,
      target: _dragTarget,
      spring: _tokens.pointerReturn,
      dt: dt,
    );
    displacement = nextDisplacement.$1;
    displacementVelocity = nextDisplacement.$2;
    displacement = LiquidSpring.limitOffset(displacement, _tokens.maxDrag);
    _idleAfterPointer += dt;
    trackBackdropBlur(
      pointerSpeedPx:
          pointerVelocity.distance * math.exp(-_idleAfterPointer * 7.0) +
          displacementVelocity.distance * 0.5,
      morphSpeed: math.max(morphVelocity.abs(), separationVelocity.abs()),
      dt: dt,
    );
    lightPosition = Offset.lerp(
      lightPosition,
      _lightTarget,
      1 - math.exp(-dt * 22),
    )!;

    morph = morph.clamp(-0.035, 1.065);
    separation = separation.clamp(-0.035, 1.055);
    press = press.clamp(0.0, 1.08);
    submitEnergy = submitEnergy.clamp(0.0, 1.0);
    if (!_pointerDown &&
        press < 0.01 &&
        displacement.distance < 0.08 &&
        displacementVelocity.distance < 0.8) {
      _materialTarget = GlassPointerTarget.none;
    }

    if (_wantsOpen) {
      state =
          (_isClose(morph, 1) &&
              morphVelocity.abs() < 0.015 &&
              _isClose(separation, 1) &&
              separationVelocity.abs() < 0.015)
          ? GlassInteractionState.open
          : GlassInteractionState.opening;
    } else if (!_pointerDown &&
        _isClose(morph, 0) &&
        morphVelocity.abs() < 0.015 &&
        _isClose(separation, 0) &&
        separationVelocity.abs() < 0.015 &&
        settleWobble.abs() < 0.02 &&
        settleWobbleVelocity.abs() < 0.15) {
      state = GlassInteractionState.idle;
    } else if (!_pointerDown || morph > 0.08) {
      state = GlassInteractionState.closing;
    }
  }

  static bool _isClose(double value, double target) =>
      (value - target).abs() < 0.002;
}
