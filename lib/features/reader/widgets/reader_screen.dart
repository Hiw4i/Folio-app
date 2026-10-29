import 'dart:async';

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import '../../../shared/diagnostics/app_log.dart';
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
import '../pdf/widgets/pdf_document_view.dart';
import '../powerpoint/widgets/powerpoint_document_view.dart';
import '../text/widgets/text_document_view.dart';
import '../word/widgets/word_document_view.dart';
import 'file_info_sheet.dart';
import 'reader_chrome.dart';
import 'reader_menu_overlays.dart';
import 'reader_search_navigator.dart';
import 'reader_status_views.dart';
import 'reader_loading_view.dart';
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
  final AutoScrollController _scrollController = AutoScrollController(
    axis: Axis.vertical,
    suggestedRowHeight: 3200,
  );
  final GlobalKey<LiquidSearchControlState> _searchKey =
      GlobalKey<LiquidSearchControlState>();
  final GlobalKey<LiquidMorphingControlState> _menuKey =
      GlobalKey<LiquidMorphingControlState>();
  final GlobalKey<LiquidMorphingControlState> _exitKey =
      GlobalKey<LiquidMorphingControlState>();
  GlobalKey _activeHitKey = GlobalKey();
  late final DocumentRenderer _renderer;
  late final AnimationController _chromeController;
  late final CurvedAnimation _chromeProgress;
  final ValueNotifier<int> _progressPercent = ValueNotifier<int>(0);
  Timer? _searchDebounce;
  Timer? _initialLoadDelay;
  int _revealGeneration = 0;
  bool _chromeTarget = true;
  bool _searchExpanded = false;
  bool _menuOpen = false;
  bool _exitOpen = false;
  bool _infoOpen = false;
  int _lastActiveHit = -2;
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
    _renderer.addListener(_rendererChanged);
    _scrollController.addListener(_scrollChanged);
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
    if (!mounted || _lastActiveHit == _renderer.activeHitIndex) {
      return;
    }
    _lastActiveHit = _renderer.activeHitIndex;
    final generation = ++_revealGeneration;
    _activeHitKey = GlobalKey(
      debugLabel: 'reader active search hit ${_renderer.activeHitIndex}',
    );
    if (_renderer.activeHit != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_revealActiveHit(generation));
      });
    }
  }

  void _scrollChanged() {
    if (!_scrollController.hasClients) {
      return;
    }
    final extent = _scrollController.position.maxScrollExtent;
    final next = extent <= 0
        ? 0
        : (_scrollController.offset / extent * 100).round().clamp(0, 100);
    if (next != _progressPercent.value) {
      _progressPercent.value = next;
    }
  }

  Future<void> _revealActiveHit(int generation) async {
    if (!mounted || !_scrollController.hasClients) {
      return;
    }
    final renderer = _renderer;
    if (renderer is! TextDocumentRenderer || renderer.activeHit == null) {
      return;
    }
    final content = renderer.content;
    if (content == null || content.chunks.isEmpty) {
      return;
    }
    final hit = renderer.activeHit!;
    final chunkIndex = hit.chunkIndex;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (_activeHitKey.currentContext == null) {
      try {
        await _scrollController.scrollToIndex(
          chunkIndex,
          preferPosition: AutoScrollPosition.begin,
          duration: reducedMotion ? Duration.zero : AppDurations.fast,
        );
      } catch (error, stack) {
        // Route disposal can invalidate the target between scheduling and
        // scrolling; debug-only visibility, the failure is expected.
        AppLog.d('Active-hit scroll skipped: $error\n$stack');
        return;
      }
    }
    if (!mounted || generation != _revealGeneration) {
      return;
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _revealGeneration) {
      return;
    }

    final targetContext = _activeHitKey.currentContext;
    final targetObject = targetContext?.findRenderObject();
    if (targetContext == null ||
        !targetContext.mounted ||
        targetObject == null ||
        !targetObject.attached) {
      return;
    }
    final paragraph = content.isMarkdown
        ? null
        : _findRenderParagraph(targetObject);
    final revealObject = paragraph ?? targetObject;
    final viewport = RenderAbstractViewport.maybeOf(revealObject);
    if (viewport == null) {
      return;
    }
    if (!_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    var targetOffset = viewport.getOffsetToReveal(revealObject, 0.28).offset;
    if (paragraph != null) {
      final chunk = content.chunks[chunkIndex];
      final localStart = (hit.startOffset - chunk.startOffset).clamp(
        0,
        chunk.text.length,
      );
      final localEnd = (hit.endOffset - chunk.startOffset).clamp(
        localStart,
        chunk.text.length,
      );
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: localStart, extentOffset: localEnd),
      );
      if (boxes.isNotEmpty) {
        targetOffset =
            viewport.getOffsetToReveal(paragraph, 0).offset +
            boxes.first.top -
            position.viewportDimension * 0.28;
      }
    }
    targetOffset = targetOffset.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((position.pixels - targetOffset).abs() < 1) {
      return;
    }
    if (reducedMotion) {
      _scrollController.jumpTo(targetOffset);
      return;
    }
    try {
      await _scrollController.animateTo(
        targetOffset,
        duration: AppDurations.fast,
        curve: AppCurves.emphasized,
      );
    } catch (error, stack) {
      // A newer search result or route disposal can cancel this animation.
      AppLog.d('Active-hit reveal animation skipped: $error\n$stack');
    }
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
    // content taps always remain available as a manual toggle.
    if (_renderer is PowerPointDocumentRenderer ||
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

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _initialLoadDelay?.cancel();
    _revealGeneration += 1;
    _renderer.removeListener(_rendererChanged);
    releaseDocumentRenderer(_renderer);
    _scrollController
      ..removeListener(_scrollChanged)
      ..dispose();
    _chromeProgress.dispose();
    _chromeController.dispose();
    _progressPercent.dispose();
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
                  builder: (context, child) => _ReaderBody(
                    renderer: _renderer,
                    scrollController: _scrollController,
                    activeHitKey: _activeHitKey,
                    onContentTap: _handleContentTap,
                    onTextSelectionChanged: _textSelectionChanged,
                    onReadingGesture: _handleVerticalReadingGesture,
                  ),
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
                        animation: _renderer,
                        builder: (context, child) {
                          return ValueListenableBuilder<int>(
                            valueListenable: _progressPercent,
                            builder: (context, percent, _) {
                              return ReaderProgressPill(
                                key: const ValueKey<String>('reader_progress_glass'),
                                label: _renderer is TextDocumentRenderer
                                    ? '$percent%'
                                    : _renderer is PdfDocumentRenderer
                                    ? _renderer.positionLabel
                                    : _renderer is OfficeDocumentRendererBase
                                    ? _renderer.positionLabel
                                    : widget.document.format.extension
                                          .toUpperCase(),
                              );
                            },
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
                    child: ReaderScrubber(
                      renderer: _renderer,
                      scrollController: _scrollController,
                      progressPercent: _progressPercent,
                    ),
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

RenderParagraph? _findRenderParagraph(RenderObject root) {
  if (root is RenderParagraph) {
    return root;
  }
  RenderParagraph? result;
  root.visitChildren((child) {
    result ??= _findRenderParagraph(child);
  });
  return result;
}

class _ReaderBody extends StatelessWidget {
  const _ReaderBody({
    required this.renderer,
    required this.scrollController,
    required this.activeHitKey,
    required this.onContentTap,
    required this.onReadingGesture,
    required this.onTextSelectionChanged,
  });

  final DocumentRenderer renderer;
  final AutoScrollController scrollController;
  final GlobalKey activeHitKey;
  final VoidCallback onContentTap;
  final ValueChanged<double> onReadingGesture;
  final ValueChanged<bool> onTextSelectionChanged;

  @override
  Widget build(BuildContext context) {
    // One loading surface for every format. Office keeps its platform view
    // mounted underneath and crossfades: the WebView's own HTML status is
    // never shown (transparent background, opacity 0 until ready).
    if (renderer.loadState == ReaderLoadState.failed) {
      return ReaderFailureView(
        failure: renderer.failure!,
        onRetry: renderer.open,
      );
    }
    if (renderer is TextDocumentRenderer) {
      final text = renderer as TextDocumentRenderer;
      if (renderer.loadState == ReaderLoadState.loading) {
        return ReaderLoadingView(document: renderer.document);
      }
      final content = text.content;
      if (content == null || content.chunks.isEmpty) {
        return const ReaderStatusView(
          title: 'Nothing to display',
          message: 'This document has no readable content.',
        );
      }
      return ReaderContentFadeIn(
        child: TextDocumentView(
          renderer: text,
          scrollController: scrollController,
          activeHitKey: activeHitKey,
          onSelectionChanged: onTextSelectionChanged,
        ),
      );
    }
    if (renderer is PdfDocumentRenderer) {
      final pdf = renderer as PdfDocumentRenderer;
      // Progressive loading: as soon as the document reference exists the
      // viewer mounts and streams pages; its internal banner (same unified
      // design) covers the remaining wait. The fade wrapper sits at a stable
      // position so the viewer state survives the loading → ready rebuild.
      if (!pdf.sourceReady) {
        return ReaderLoadingView(document: renderer.document);
      }
      return ReaderContentFadeIn(
        child: PdfDocumentView(
          renderer: pdf,
          onContentTap: onContentTap,
          onVerticalReadingGesture: onReadingGesture,
        ),
      );
    }
    if (renderer is OfficeDocumentRendererBase) {
      final office = renderer as OfficeDocumentRendererBase;
      if (!office.sourceReady) {
        return ReaderLoadingView(document: renderer.document);
      }
      final Widget view = renderer is WordDocumentRenderer
          ? WordDocumentView(
              renderer: renderer as WordDocumentRenderer,
              onContentTap: onContentTap,
              onReadingGesture: onReadingGesture,
            )
          : PowerPointDocumentView(
              renderer: renderer as PowerPointDocumentRenderer,
              onContentTap: onContentTap,
            );
      return _OfficeStagedView(renderer: office, view: view);
    }
    if (renderer.loadState == ReaderLoadState.ready) {
      return const ReaderStatusView(
        title: 'Nothing to display',
        message: 'This document has no readable content.',
      );
    }
    return ReaderLoadingView(document: renderer.document);
  }
}

/// Office staged reveal: the platform view stays mounted at opacity 0 while
/// rendering (warming under the Flutter loader), then crossfades with the
/// loader overlay instead of swapping to the WebView's own status text.
///
/// While at opacity 0 the platform view is not painted, so its Android view is
/// not attached to a window yet. Native events must therefore be delivered
/// independently of window attachment (see `OfficePlatformView.emit`), or the
/// `ready` handshake would deadlock.
class _OfficeStagedView extends StatefulWidget {
  const _OfficeStagedView({required this.renderer, required this.view});

  final OfficeDocumentRendererBase renderer;
  final Widget view;

  @override
  State<_OfficeStagedView> createState() => _OfficeStagedViewState();
}

class _OfficeStagedViewState extends State<_OfficeStagedView> {
  static const Duration _crossfade = Duration(milliseconds: 240);

  bool _overlayVisible = true;
  bool _overlayOpaque = true;
  Timer? _overlayTimer;

  bool get _ready => widget.renderer.loadState == ReaderLoadState.ready;

  @override
  void initState() {
    super.initState();
    _overlayVisible = !_ready;
    _overlayOpaque = !_ready;
    widget.renderer.addListener(_rendererChanged);
  }

  @override
  void didUpdateWidget(_OfficeStagedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.renderer, widget.renderer)) {
      oldWidget.renderer.removeListener(_rendererChanged);
      widget.renderer.addListener(_rendererChanged);
      _overlayTimer?.cancel();
      _overlayVisible = !_ready;
      _overlayOpaque = !_ready;
    }
  }

  void _rendererChanged() {
    if (!mounted) {
      return;
    }
    if (_ready && _overlayOpaque) {
      setState(() => _overlayOpaque = false);
      _overlayTimer?.cancel();
      _overlayTimer = Timer(_crossfade, () {
        if (mounted && _ready) {
          setState(() => _overlayVisible = false);
        }
      });
    }
  }

  @override
  void dispose() {
    _overlayTimer?.cancel();
    widget.renderer.removeListener(_rendererChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final ready = _ready;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        AnimatedOpacity(
          opacity: ready ? 1 : 0,
          duration: reducedMotion ? Duration.zero : _crossfade,
          curve: Curves.easeOutCubic,
          child: IgnorePointer(ignoring: !ready, child: widget.view),
        ),
        // Mounted immediately (no grace): preparation already proved slow by
        // reaching this stage, so hiding the loader here would flash empty
        // background. The overlay then crossfades out on `ready`.
        if (_overlayVisible)
          AnimatedOpacity(
            opacity: _overlayOpaque ? 1 : 0,
            duration: reducedMotion ? Duration.zero : _crossfade,
            curve: Curves.easeOutCubic,
            child: ReaderLoadingView(
              document: widget.renderer.document,
              immediate: true,
            ),
          ),
      ],
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
