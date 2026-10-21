import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../settings/folio_settings_scope.dart';

import '../core/glass_geometry.dart';
import '../core/glass_tokens.dart';
import '../motion/glass_motion_controller.dart';
import 'liquid_search_morph.dart';

class LiquidSearchControl extends StatefulWidget {
  const LiquidSearchControl({
    required this.onChanged,
    this.initialQuery = '',
    this.hintText = 'Search documents',
    this.semanticsLabel = 'Search',
    this.onSubmitted,
    this.onExpansionChanged,
    this.active = true,
    super.key,
  });

  final ValueChanged<String> onChanged;
  final String initialQuery;
  final String hintText;
  final String semanticsLabel;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<bool>? onExpansionChanged;

  /// When false, the control keeps its visual state but no longer claims the
  /// system Back gesture or requests input focus. Used while a covering reader
  /// owns navigation; the owning screen restores [active] on return.
  final bool active;

  @override
  State<LiquidSearchControl> createState() => LiquidSearchControlState();
}

class LiquidSearchControlState extends State<LiquidSearchControl>
    with SingleTickerProviderStateMixin {
  static const double height = 176;
  static const GlassTokens _tokens = GlassTokens();

  late final GlassMotionController _motion;
  late final TextEditingController _searchController;
  final FocusNode _searchFocus = FocusNode(debugLabel: 'Search field');
  final FocusNode _mainFocus = FocusNode(debugLabel: 'Search button');
  final FocusNode _cancelFocus = FocusNode(debugLabel: 'Cancel button');
  final GlobalKey<EditableTextState> _editableKey =
      GlobalKey<EditableTextState>(debugLabel: 'Search editable');
  Timer? _keyboardRetry;
  int? _primaryPointer;
  bool _focusRequested = false;
  bool _reducedMotion = false;
  bool _wasExpanded = false;
  bool _reportedExpanded = false;
  bool _focusSyncScheduled = false;

  bool get isExpanded => _motion.wantsOpen || _motion.morph > 0.02;

  void open() {
    _motion.requestOpen();
    if (_motion.state == GlassInteractionState.open) {
      _requestInputFocus();
    }
  }

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.initialQuery)
      ..addListener(_queryChanged);
    _motion = GlassMotionController(vsync: this)..addListener(_syncFocus);
    _searchFocus.addListener(_focusChanged);
    _mainFocus.addListener(_focusChanged);
    _cancelFocus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(LiquidSearchControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) {
      _keyboardRetry?.cancel();
      _focusRequested = false;
      _searchFocus.unfocus();
      _cancelFocus.unfocus();
      if (defaultTargetPlatform == TargetPlatform.windows) {
        _mainFocus.unfocus();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion.setLiquidMotionEnabled(
      FolioSettingsScope.liquidMotionEnabledOf(context),
    );
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (reducedMotion != _reducedMotion) {
      _reducedMotion = reducedMotion;
      _motion.setReducedMotion(reducedMotion);
    }
  }

  void _queryChanged() {
    widget.onChanged(_searchController.text);
  }

  void _focusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _syncFocus() {
    // A settings dependency can snap a closing spring while this subtree is
    // building. Clearing its query may rebuild an ancestor catalog/reader;
    // defer only that build-phase side effect, not ordinary animation ticks.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (!_focusSyncScheduled) {
        _focusSyncScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _focusSyncScheduled = false;
          if (mounted) {
            _syncFocus();
          }
        });
      }
      return;
    }
    if (_reportedExpanded != _motion.wantsOpen) {
      _reportedExpanded = _motion.wantsOpen;
      widget.onExpansionChanged?.call(_reportedExpanded);
    }
    if (widget.active &&
        _motion.wantsOpen &&
        _motion.morph > 0.94 &&
        !_focusRequested) {
      _focusRequested = true;
      _wasExpanded = true;
      _requestInputFocus();
    }
    if (_focusRequested &&
        (!widget.active || (!_motion.wantsOpen && _motion.morph < 0.62))) {
      _focusRequested = false;
      _searchFocus.unfocus();
      _cancelFocus.unfocus();
      if (widget.active && defaultTargetPlatform == TargetPlatform.windows) {
        _mainFocus.requestFocus();
      }
    }
    if (_wasExpanded &&
        _motion.state == GlassInteractionState.idle &&
        _searchController.text.isNotEmpty) {
      _wasExpanded = false;
      _searchController.clear();
    }
  }

  void _requestInputFocus() {
    if (!widget.active || !_motion.wantsOpen || !mounted) {
      return;
    }
    _searchFocus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_motion.wantsOpen) {
        return;
      }
      _showKeyboardIfReady();
      _keyboardRetry?.cancel();
      _keyboardRetry = Timer(
        const Duration(milliseconds: 110),
        _showKeyboardIfReady,
      );
    });
  }

  void _showKeyboardIfReady() {
    if (!widget.active ||
        !mounted ||
        !_motion.wantsOpen ||
        !_searchFocus.hasFocus) {
      return;
    }
    _editableKey.currentState?.requestKeyboard();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
  }

  void close() {
    if (_motion.morph > 0.02 || _motion.wantsOpen) {
      _keyboardRetry?.cancel();
      _motion.requestClose();
    }
  }

  bool handleBack() {
    if (_searchFocus.hasFocus) {
      _searchFocus.unfocus();
      return true;
    }
    if (isExpanded) {
      close();
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    _keyboardRetry?.cancel();
    _motion
      ..removeListener(_syncFocus)
      ..dispose();
    _searchController
      ..removeListener(_queryChanged)
      ..dispose();
    _searchFocus.dispose();
    _mainFocus.dispose();
    _cancelFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): close,
      },
      child: FocusTraversalGroup(
        child: AnimatedBuilder(
          animation: _motion,
          builder: (context, child) {
            final collapsed = !_motion.wantsOpen && _motion.morph < 0.02;
            return PopScope<void>(
              canPop: !widget.active || collapsed,
              onPopInvokedWithResult: (didPop, result) {
                if (!didPop && widget.active && !collapsed) {
                  handleBack();
                }
              },
              child: child!,
            );
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.biggest;
              final bottomPadding = MediaQuery.viewPaddingOf(context).bottom;
              final centerY = size.height - bottomPadding - 45;
              return AnimatedBuilder(
                animation: _motion,
                builder: (context, child) {
                  final cancelOwnsDisplacement =
                      _motion.materialTarget == GlassPointerTarget.cancel;
                  final frame = GlassGeometry.resolve(
                    viewport: size,
                    morph: _motion.morph,
                    separation: _motion.separation,
                    displacement: cancelOwnsDisplacement
                        ? Offset.zero
                        : _motion.displacement,
                    cancelDisplacement: cancelOwnsDisplacement
                        ? _motion.displacement
                        : Offset.zero,
                    pointerPosition: _motion.lightPosition,
                    press: _motion.press,
                    pointerVelocity: _motion.pointerVelocity,
                    settleWobble: _motion.settleWobble,
                    deformCancel:
                        _motion.materialTarget == GlassPointerTarget.cancel,
                    collapsedCenter: Offset(
                      size.width - _tokens.horizontalMargin - 27,
                      centerY,
                    ),
                    anchorExpandedRight: true,
                    centerY: centerY,
                  );
                  return Listener(
                    behavior: HitTestBehavior.deferToChild,
                    onPointerDown: (event) {
                      if (_primaryPointer != null) {
                        return;
                      }
                      final target = frame.hitCancel(event.localPosition)
                          ? GlassPointerTarget.cancel
                          : frame.hitMain(event.localPosition)
                          ? GlassPointerTarget.main
                          : GlassPointerTarget.none;
                      if (target == GlassPointerTarget.none) {
                        return;
                      }
                      if (target == GlassPointerTarget.main &&
                          frame.morph < 0.68) {
                        _mainFocus.requestFocus();
                      }
                      _primaryPointer = event.pointer;
                      _motion.beginPointer(
                        position: event.localPosition,
                        timestamp: event.timeStamp,
                        target: target,
                      );
                    },
                    onPointerMove: (event) {
                      if (_primaryPointer == event.pointer) {
                        _motion.movePointer(
                          position: event.localPosition,
                          timestamp: event.timeStamp,
                        );
                      }
                    },
                    onPointerUp: (event) {
                      if (_primaryPointer == event.pointer) {
                        _motion.endPointer(
                          position: event.localPosition,
                          timestamp: event.timeStamp,
                        );
                        _primaryPointer = null;
                      }
                    },
                    onPointerCancel: (event) {
                      if (_primaryPointer == event.pointer) {
                        _motion.cancelPointer();
                        _primaryPointer = null;
                      }
                    },
                    child: RepaintBoundary(
                      child: LiquidSearchMorph(
                        frame: frame,
                        motion: _motion,
                        searchController: _searchController,
                        editableKey: _editableKey,
                        searchFocus: _searchFocus,
                        mainFocus: _mainFocus,
                        cancelFocus: _cancelFocus,
                        reducedMotion: _reducedMotion,
                        hintText: widget.hintText,
                        semanticsLabel: widget.semanticsLabel,
                        onSubmitted: widget.onSubmitted,
                        onTapInput: _requestInputFocus,
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
