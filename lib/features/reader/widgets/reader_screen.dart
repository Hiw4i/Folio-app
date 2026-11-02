import 'dart:async';

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../../shared/glass/liquid_glass.dart';
import '../../../shared/settings/folio_settings_scope.dart';
import '../../../shared/theme/folio_theme.dart';
import '../../library/data/document_entry.dart';
import '../data/document_content_source.dart';
import '../logic/chrome_visibility.dart';
import '../logic/document_renderer.dart';
import '../logic/reader_state.dart';
import '../logic/renderer_lifecycle.dart';
import '../logic/title_truncation.dart';
import 'file_info_sheet.dart';
import 'bindings/reader_binding.dart';
import 'bindings/reader_binding_factory.dart';
import 'reader_chrome.dart';
import 'reader_menu_overlays.dart';
import 'reader_search_navigator.dart';
import 'reader_status_views.dart';
import 'reader_scrubber.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    required this.document,
    required this.contentSource,
    required this.onRemoveFromRecents,
    this.deferInitialLoad = false,
    this.initialRenderer,
    this.onDisposed,
    this.openedExternally = false,
    this.onReturnToMain,
    super.key,
  }) : assert(
         !openedExternally || onReturnToMain != null,
         'Externally launched readers must provide onReturnToMain.',
       );

  final DocumentEntry document;
  final DocumentContentSource contentSource;
  final Future<void> Function() onRemoveFromRecents;

  /// Lets the container transform render without competing with document I/O.
  final bool deferInitialLoad;

  /// A renderer already warming via [ReaderPreloader]. When provided, the
  /// screen adopts it as-is and never restarts its in-flight [open].
  final DocumentRenderer? initialRenderer;

  /// Releases the library navigation gate even if its originating list row
  /// moved to Recents and its OpenContainer was removed while reading.
  final VoidCallback? onDisposed;

  /// True when the document came from an external launch. The primary exit
  /// closes the app, while the expanded menu can also reveal the library.
  final bool openedExternally;

  /// Reveals the library beneath an externally launched reader. The reader is
  /// the home-route child rather than a route, so this is not a Navigator pop.
  final VoidCallback? onReturnToMain;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with SingleTickerProviderStateMixin {
  final GlobalKey<LiquidSearchControlState> _searchKey =
      GlobalKey<LiquidSearchControlState>();
  final GlobalKey<LiquidMorphingControlState> _menuKey =
      GlobalKey<LiquidMorphingControlState>();
  final GlobalKey<LiquidMorphingControlState> _exitKey =
      GlobalKey<LiquidMorphingControlState>();
  late final DocumentRenderer _renderer;

  /// The one UI adapter for the active renderer, chosen once by the binding
  /// factory. It owns the format's UI-side resources (navigation, text scroll
  /// controller, percent projection) and builds the document surface.
  late final ReaderBinding _binding;
  late final AnimationController _chromeController;
  late final CurvedAnimation _chromeProgress;
  Timer? _searchDebounce;
  Timer? _initialLoadDelay;
  bool _chromeTarget = true;
  bool _searchExpanded = false;
  bool _menuOpen = false;
  bool _exitOpen = false;
  bool _infoOpen = false;
  int? _contentPointer;
  Offset? _contentPointerOrigin;
  bool _contentPointerMoved = false;
  Duration? _contentPointerStarted;
  bool _textSelectionActive = false;
  bool _chromeReducedMotion = false;
  final ChromeScrollIntentAccumulator _scrollIntent =
      ChromeScrollIntentAccumulator(threshold: ReaderChromeSpec.scrollIntentDistance);
  bool _showNavigationOnScrollUp = true;

  @override
  void initState() {
    super.initState();
    _chromeController = AnimationController(
      vsync: this,
      duration: ReaderChromeSpec.showDuration,
      reverseDuration: ReaderChromeSpec.hideDuration,
      value: 1,
    );
    _chromeProgress = CurvedAnimation(
      parent: _chromeController,
      curve: ReaderChromeSpec.showCurve,
      reverseCurve: ReaderChromeSpec.hideCurve,
    );
    _renderer =
        widget.initialRenderer ??
        createDocumentRenderer(
          document: widget.document,
          contentSource: widget.contentSource,
        );
    _binding = createReaderBinding(_renderer);
    _renderer.addListener(_rendererChanged);
    // A text viewport attaching to its scroll controller produces no
    // notification; revalidate after the first frame so the scrubber state
    // reflects the attached viewport.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _binding.navigation.revalidate();
      }
    });
    if (widget.initialRenderer != null) {
      // A primed renderer is already opening (or open): adopt it without
      // restarting its in-flight work, so I/O overlapped the open animation.
    } else if (widget.deferInitialLoad) {
      // Matches the OpenContainer morph so document I/O never competes with
      // the transition (the primed path skips this entirely).
      _initialLoadDelay = Timer(AppDurations.medium, () {
        if (mounted) {
          unawaited(_renderer.open());
        }
      });
    } else {
      unawaited(_renderer.open());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final showOnScrollUp = FolioSettingsScope.settingsOf(context)
        .showNavigationOnScrollUp;
    if (showOnScrollUp != _showNavigationOnScrollUp) {
      _showNavigationOnScrollUp = showOnScrollUp;
      // A preference change must not complete a half-recorded scroll intent.
      _scrollIntent.reset();
    }
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (reducedMotion != _chromeReducedMotion) {
      _chromeReducedMotion = reducedMotion;
      _chromeController.duration = reducedMotion
          ? Duration.zero
          : ReaderChromeSpec.showDuration;
      _chromeController.reverseDuration = reducedMotion
          ? Duration.zero
          : ReaderChromeSpec.hideDuration;
    }
  }

  void _setChromeTarget(bool visible) {
    _scrollIntent.reset();
    if (_chromeTarget == visible) {
      return;
    }
    _chromeTarget = visible;
    _driveChrome();
  }

  void _driveChrome() {
    if (!mounted) {
      return;
    }
    final shouldShow = _chromeTarget || _searchExpanded;
    if (shouldShow) {
      if (!_chromeController.isCompleted &&
          _chromeController.status != AnimationStatus.forward) {
        _chromeController.forward();
      }
    } else {
      if (!_chromeController.isDismissed &&
          _chromeController.status != AnimationStatus.reverse) {
        _chromeController.reverse();
      }
    }
  }

  void _rendererChanged() {
    // The navigation snapshot must follow renderer transitions (a PDF
    // attaching its viewer, Office posting ready) even when no scroll or
    // progress source fires. Revalidated post-frame because the format view
    // that attaches the viewport builds in response to this notification.
    // Search-hit reveals are owned by the text surface.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _binding.navigation.revalidate();
      }
    });
  }

  void _searchChanged(String query) {
    _searchDebounce?.cancel();
    _setChromeTarget(true);
    if (query.trim().isEmpty) {
      unawaited(_renderer.search(''));
      return;
    }
    _searchDebounce = Timer(
      AppDurations.fast,
      () => unawaited(_renderer.search(query)),
    );
  }

  Future<void> _openFileInfo() async {
    if (!mounted || _infoOpen) {
      return;
    }
    setState(() => _infoOpen = true);
    _menuKey.currentState?.close();
    _exitKey.currentState?.close();
    _clearContentPointer();
    _scrollIntent.reset();
    try {
      await showFolioFileInfoSheet(context, document: widget.document);
    } finally {
      if (mounted) {
        setState(() => _infoOpen = false);
      }
    }
  }

  void _handleBackButton() {
    // File info is a separate modal route. Keep the reader locked until its
    // reverse transition and backdrop finish, including repeated Back taps.
    if (_infoOpen) {
      return;
    }
    if (_exitOpen) {
      _exitKey.currentState?.close();
      return;
    }
    if (_menuOpen) {
      _menuKey.currentState?.close();
      return;
    }
    if (_searchKey.currentState?.handleBack() ?? false) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    if (widget.openedExternally) {
      unawaited(SystemNavigator.pop());
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _closeApp() {
    _exitKey.currentState?.close();
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(SystemNavigator.pop());
  }

  void _returnToMain() {
    _exitKey.currentState?.close();
    _searchKey.currentState?.close();
    FocusManager.instance.primaryFocus?.unfocus();
    final returnToMain = widget.onReturnToMain;
    if (returnToMain != null) {
      returnToMain();
    } else {
      Navigator.of(context).pop();
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    // PDF and Office already report classified reading gestures. Only the
    // top-level vertical text viewport should also use Flutter notifications;
    // nested Markdown code/table scrollers must not affect the reader chrome.
    if (_renderer is! TextDocumentRenderer ||
        notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical ||
        _searchExpanded ||
        _textSelectionActive) {
      return false;
    }
    if (notification case ScrollUpdateNotification(
      :final scrollDelta,
      :final dragDetails,
      :final metrics,
    )) {
      // Ballistic bounce and search's programmatic reveal must not reopen or
      // close the reading chrome. Only the user's actual drag expresses
      // intent to change the controls.
      if (dragDetails != null) {
        _recordChromeScroll(scrollDelta ?? 0, canHide: metrics.pixels > 24);
      }
    } else if (notification is ScrollStartNotification ||
        notification is ScrollEndNotification) {
      _scrollIntent.reset();
    }
    return false;
  }

  void _recordChromeScroll(double delta, {required bool canHide}) {
    // Slides have their own centre-tap contract. Neither horizontal swipes,
    // native scroll messages nor programmatic navigation may alter chrome.
    // When scroll-driven navigation is disabled the panels ignore scrolling
    // entirely (both auto-hide on scroll down and reveal on scroll up);
    // content taps always remain available as a manual toggle. The rule is
    // the binding's, not a type check here.
    if (!_binding.interactionPolicy.scrollControlsChrome ||
        _searchExpanded ||
        _menuOpen ||
        _exitOpen ||
        _infoOpen ||
        _textSelectionActive ||
        !_showNavigationOnScrollUp ||
        !delta.isFinite ||
        delta == 0) {
      if (!_showNavigationOnScrollUp) {
        _scrollIntent.reset();
      }
      return;
    }
    switch (_scrollIntent.record(delta, visible: _chromeTarget, canHide: canHide)) {
      case ChromeVisibilityCommand.hide:
        _setChromeTarget(false);
      case ChromeVisibilityCommand.show:
        _setChromeTarget(true);
      case ChromeVisibilityCommand.stay:
        break;
    }
  }

  void _handleContentTap() {
    if (_searchExpanded ||
        _menuOpen ||
        _exitOpen ||
        _infoOpen ||
        _textSelectionActive) {
      return;
    }
    // Every format uses the same target, not the current animated opacity.
    // A second tap can reverse an in-flight hide/show without losing intent.
    // PPTX sends only centre taps; its edge taps remain slide navigation.
    _setChromeTarget(!_chromeTarget);
  }

  void _contentPointerDown(PointerDownEvent event) {
    // Only text needs the raw-pointer fallback. PDF and Office already
    // classify taps (including selection, slide edges and multi-touch).
    // Listening twice would toggle PPTX chrome twice or reveal it on edges.
    if (_renderer is! TextDocumentRenderer) {
      return;
    }
    if (_contentPointer != null) {
      _contentPointerMoved = true;
      return;
    }
    if (event.buttons != kPrimaryButton) {
      return;
    }
    _contentPointer = event.pointer;
    _contentPointerOrigin = event.position;
    _contentPointerMoved = _textSelectionActive;
    _contentPointerStarted = event.timeStamp;
  }

  void _contentPointerMove(PointerMoveEvent event) {
    if (event.pointer != _contentPointer) {
      return;
    }
    final origin = _contentPointerOrigin;
    // A movement of exactly the tap slop is already a scroll intent. With a
    // strict `>` a 10px scroll was reported as a tap, toggling the chrome
    // instead of reading the document.
    if (origin != null && (event.position - origin).distance >= 10) {
      _contentPointerMoved = true;
    }
  }

  void _contentPointerUp(PointerUpEvent event) {
    if (event.pointer != _contentPointer) {
      return;
    }
    final started = _contentPointerStarted;
    final isTap =
        !_contentPointerMoved &&
        !_textSelectionActive &&
        started != null &&
        event.timeStamp - started < AppDurations.medium;
    _clearContentPointer();
    if (isTap) {
      _handleContentTap();
    }
  }

  void _contentPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _contentPointer) {
      _clearContentPointer();
    }
  }

  void _clearContentPointer() {
    _contentPointer = null;
    _contentPointerOrigin = null;
    _contentPointerStarted = null;
    _contentPointerMoved = false;
  }

  void _textSelectionChanged(bool active) {
    _textSelectionActive = active;
    if (active) {
      _contentPointerMoved = true;
      _scrollIntent.reset();
    }
  }

  void _handleVerticalReadingGesture(double scrollDelta) {
    if (_searchExpanded) {
      return;
    }
    _recordChromeScroll(scrollDelta, canHide: true);
  }

  /// The document surface for the active renderer. Failure handling stays in
  /// the shell (it owns retry and chrome reset); everything format-specific —
  /// loading stages, empty states, the surface itself — lives in the binding.
  Widget _buildDocumentSurface() {
    final renderer = _renderer;
    if (renderer.loadState == ReaderLoadState.failed) {
      return ReaderFailureView(
        failure: renderer.failure!,
        onRetry: renderer.open,
      );
    }
    return _binding.buildSurface(
      ReaderSurfaceCallbacks(
        onContentTap: _handleContentTap,
        onReadingDrag: (delta, canHide) {
          if (canHide) {
            _handleVerticalReadingGesture(delta);
          }
        },
        onSelectionChanged: _textSelectionChanged,
      ),
    );
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _initialLoadDelay?.cancel();
    _renderer.removeListener(_rendererChanged);
    _binding.dispose();
    releaseDocumentRenderer(_renderer);
    _chromeProgress.dispose();
    _chromeController.dispose();
    widget.onDisposed?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final reducedMotion = media.disableAnimations;
    final navigatorFadeDuration = reducedMotion
        ? Duration.zero
        : AppDurations.fastest;
    return PopScope<void>(
      canPop: !_menuOpen && !_exitOpen && !_infoOpen,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || _infoOpen) {
          return;
        }
        if (_exitOpen) {
          _exitKey.currentState?.close();
          return;
        }
        if (_menuOpen) {
          _menuKey.currentState?.close();
        }
      },
      child: ColoredBox(
        key: const ValueKey<String>('reader_surface'),
        color: appColors.background,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            const ReaderBackground(),
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _contentPointerDown,
              onPointerMove: _contentPointerMove,
              onPointerUp: _contentPointerUp,
              onPointerCancel: _contentPointerCancel,
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScrollNotification,
                child: AnimatedBuilder(
                  animation: _renderer,
                  builder: (context, child) => _buildDocumentSurface(),
                ),
              ),
            ),
            BackdropGroup(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Positioned(
                    key: const ValueKey<String>('reader_top_chrome'),
                    left: 16,
                    right: 16,
                    top: media.viewPadding.top + 10,
                    height: 50,
                    child: ReaderChromeShell(
                      progress: _chromeProgress,
                      hiddenDy: ReaderChromeSpec.topHiddenDy,
                      child: _TopChromeContent(document: widget.document),
                    ),
                  ),
                  Positioned(
                    left: 20,
                    bottom:
                        media.viewInsets.bottom + media.viewPadding.bottom + 28,
                    child: ReaderChromeShell(
                      progress: _chromeProgress,
                      hiddenDy: ReaderChromeSpec.pillHiddenDy,
                      child: AnimatedBuilder(
                        animation: _binding.navigation,
                        builder: (context, child) {
                          return ReaderProgressPill(
                            key: const ValueKey<String>('reader_progress_glass'),
                            label: _binding.navigation.snapshot.positionLabel,
                          );
                        },
                      ),
                    ),
                  ),
                  Positioned(
                    key: const ValueKey<String>('reader_scrubber_slot'),
                    right: 0,
                    top: media.viewPadding.top + 76,
                    bottom:
                        media.viewInsets.bottom +
                        media.viewPadding.bottom +
                        120,
                    width: 110,
                    child: ReaderScrubber(navigation: _binding.navigation),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: media.viewInsets.bottom,
                    height:
                        LiquidSearchControlState.height +
                        media.viewPadding.bottom,
                    child: ReaderChromeShell(
                      progress: _chromeProgress,
                      hiddenDy: ReaderChromeSpec.bottomHiddenDy,
                      child: LiquidSearchControl(
                        key: _searchKey,
                        hintText: 'Search in document',
                        semanticsLabel: 'Search in document',
                        onChanged: _searchChanged,
                        onSubmitted: (_) {
                          if (_renderer.hitCount > 0) {
                            _renderer.showNextHit();
                          }
                        },
                        onExpansionChanged: (expanded) {
                          if (!mounted || _searchExpanded == expanded) {
                            return;
                          }
                          setState(() => _searchExpanded = expanded);
                          _driveChrome();
                        },
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      ignoring: _menuOpen,
                      child: ReaderChromeShell(
                        progress: _chromeProgress,
                        hiddenDy: ReaderChromeSpec.topHiddenDy,
                        child: LiquidMorphingControl(
                          key: _exitKey,
                          collapsedHitKey: const ValueKey<String>(
                            'reader_back_button',
                          ),
                          collapsedSemanticsLabel: widget.openedExternally
                              ? 'Close app'
                              : 'Back to library',
                          expandedSemanticsLabel: 'Navigation options',
                          onCollapsedTap: _handleBackButton,
                          geometryBuilder: (viewport) {
                            final top = media.viewPadding.top + 10;
                            return LiquidMorphGeometry(
                              collapsedRect: Rect.fromLTWH(16, top, 48, 48),
                              expandedRect: Rect.fromLTWH(16, top, 226, 112),
                              expandedCornerRadius: 24,
                            );
                          },
                          collapsedChild: Center(
                            child: AdaptiveGlassIcon(
                              widget.openedExternally
                                  ? LucideIcons.x
                                  : LucideIcons.chevronLeft,
                              size: 24,
                            ),
                          ),
                          expandedChild: ReaderExitMenu(
                            openedExternally: widget.openedExternally,
                            onReturnToMain: _returnToMain,
                            onCloseApp: _closeApp,
                          ),
                          onExpansionChanged: (expanded) {
                            if (!mounted || _exitOpen == expanded) {
                              return;
                            }
                            if (expanded) {
                              _menuKey.currentState?.close();
                            }
                            setState(() => _exitOpen = expanded);
                            if (expanded) {
                              _setChromeTarget(true);
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      ignoring: _exitOpen,
                      child: ReaderChromeShell(
                        progress: _chromeProgress,
                        hiddenDy: ReaderChromeSpec.topHiddenDy,
                        child: LiquidMorphingControl(
                          key: _menuKey,
                          collapsedHitKey: const ValueKey<String>(
                            'reader_menu_button',
                          ),
                          collapsedSemanticsLabel: 'Document menu',
                          expandedSemanticsLabel: 'Document menu',
                          geometryBuilder: (viewport) {
                            final top = media.viewPadding.top + 10;
                            return LiquidMorphGeometry(
                              collapsedRect: Rect.fromLTWH(
                                viewport.width - 64,
                                top,
                                48,
                                48,
                              ),
                              expandedRect: Rect.fromLTWH(
                                viewport.width - 242,
                                top,
                                226,
                                // Two 48px rows, a 1px divider and the shared
                                // 8px vertical padding: 113, not 112. The menu
                                // column overflowed by exactly the missing pixel.
                                113,
                              ),
                              expandedCornerRadius: 24,
                            );
                          },
                          collapsedChild: const Center(child: ReaderMenuGlyph()),
                          expandedChild: ReaderMenuContent(
                            onFileInfo: () => unawaited(_openFileInfo()),
                            onRemove: () {
                              _menuKey.currentState?.close();
                              unawaited(widget.onRemoveFromRecents());
                            },
                          ),
                          onExpansionChanged: (expanded) {
                            if (!mounted || _menuOpen == expanded) {
                              return;
                            }
                            if (expanded) {
                              _exitKey.currentState?.close();
                            }
                            setState(() => _menuOpen = expanded);
                            if (expanded) {
                              _setChromeTarget(true);
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 20,
                    bottom:
                        media.viewInsets.bottom +
                        media.viewPadding.bottom +
                        102,
                    child: ReaderChromeShell(
                      progress: _chromeProgress,
                      hiddenDy: ReaderChromeSpec.pillHiddenDy,
                      child: AnimatedBuilder(
                        animation: _renderer,
                        builder: (context, child) {
                          final hasQuery = _renderer.query.trim().isNotEmpty;
                          final gated =
                              hasQuery &&
                              !_menuOpen &&
                              !_exitOpen &&
                              !_infoOpen;
                          return TweenAnimationBuilder<double>(
                            tween: Tween<double>(end: gated ? 1 : 0),
                            duration: navigatorFadeDuration,
                            curve: gated
                                ? ReaderChromeSpec.showCurve
                                : ReaderChromeSpec.hideCurve,
                            builder: (context, opacity, child) =>
                                LiquidFade(opacity: opacity, child: child!),
                            child: IgnorePointer(
                              ignoring: !gated,
                              child: ExcludeSemantics(
                                excluding: !gated,
                                child: hasQuery
                                    ? ReaderSearchNavigator(renderer: _renderer)
                                    : const SizedBox.shrink(),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Horizontal padding inside the reader title pill (18pt each side).
const double _titlePadding = 36;

/// Shared truncation + measurement cache for the reader title pill: it runs
/// inside a `LayoutBuilder` on every chrome tick/resize and binary-searches
/// the truncation point, so uncached `TextPainter.layout` would allocate
/// dozens of painters per frame.
final TitleTruncator _titleTruncator = TitleTruncator();

class _TopChromeContent extends StatelessWidget {
  const _TopChromeContent({required this.document});

  final DocumentEntry document;

  static TextStyle _titleStyle(BuildContext context) =>
      AppTextStyles.bodyStrong(context).copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        letterSpacing: -0.1,
      );

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        // The liquid exit control is positioned independently by the screen.
        // The matching spacer keeps the title in the same optical centre.
        const SizedBox(width: 48, height: 48),
        const SizedBox(width: 10),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final direction = Directionality.of(context);
              final textScaler = MediaQuery.textScalerOf(context);
              final style = _titleStyle(context);
              final maxTextWidth = (constraints.maxWidth - _titlePadding).clamp(
                0.0,
                double.infinity,
              );
              // The liquid surface loosens incoming constraints (its optical
              // shell overflows the material box), so the label is truncated
              // up front and the Text gets a tight box: `ellipsis` alone
              // would never engage and the text would bleed past the glass.
              final label = _titleTruncator.truncate(
                document.name,
                style,
                maxTextWidth,
                direction,
                textScaler,
              );
              final labelWidth = _titleTruncator.measure(
                label,
                style,
                direction,
                textScaler,
              );
              final titleWidth = (labelWidth + _titlePadding).clamp(
                76.0,
                constraints.maxWidth,
              );
              final textWidth = (titleWidth - _titlePadding).clamp(
                0.0,
                double.infinity,
              );
              return Align(
                child: _LiquidChromeObject(
                  key: const ValueKey<String>('reader_title_glass'),
                  size: Size(titleWidth, 42),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: _titlePadding / 2,
                    ),
                    child: SizedBox(
                      key: const ValueKey<String>('reader_title_text_box'),
                      width: textWidth,
                      child: AdaptiveGlassText(
                        label,
                        // Screen readers announce the full name even when the
                        // pill shows the truncated form.
                        semanticsLabel: document.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: style,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 10),
        const SizedBox(width: 48, height: 48),
      ],
    );
  }
}

class _LiquidChromeObject extends StatelessWidget {
  const _LiquidChromeObject({
    required this.size,
    required this.child,
    super.key,
  });

  final Size size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Единый liquid-примитив (сам ослабляет tight-ограничения внутренним
    // OverflowBox: оптическая оболочка выступает за [size] без клиппинга).
    // Зона захвата — дефолтные 8pt, как у меню: палец цепляется одинаково.
    return LiquidGlassControl(size: size, child: child);
  }
}

