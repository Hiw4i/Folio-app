import 'package:flutter/widgets.dart';

import '../features/library/data/document_entry.dart';
import '../features/library/logic/library_controller.dart';
import '../features/library/widgets/library_screen.dart';
import '../features/reader/data/document_content_source.dart';
import '../features/reader/logic/document_renderer.dart';
import '../features/reader/logic/reader_preloader.dart';
import '../features/reader/widgets/reader_screen.dart';
import '../shared/theme/folio_theme.dart';

/// Home-route host for the library and an externally launched reader.
///
/// The external reader deliberately is not a pushed route: with the reader as
/// the home route's child, Android can show its native predictive-back exit
/// preview. The library stays mounted underneath so its scroll, filter and
/// search state survive a detour through an external document.
class FolioRoot extends StatefulWidget {
  const FolioRoot({
    required this.controller,
    required this.documentContentSource,
    this.initialExternalDocument,
    super.key,
  });

  final LibraryController controller;
  final DocumentContentSource documentContentSource;

  /// A cold-launch document already claimed from the launch intent.
  final DocumentEntry? initialExternalDocument;

  @override
  State<FolioRoot> createState() => _FolioRootState();
}

class _FolioRootState extends State<FolioRoot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _transition;
  late final CurvedAnimation _curve;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;

  DocumentEntry? _externalDocument;
  DocumentRenderer? _externalRenderer;
  int _externalGeneration = 0;
  bool _libraryOffstage = false;
  bool _closingExternal = false;

  @override
  void initState() {
    super.initState();
    _transition = AnimationController(
      vsync: this,
      duration: AppDurations.normal,
      reverseDuration: AppDurations.fast,
    );
    _curve = CurvedAnimation(
      parent: _transition,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _opacity = _curve;
    _scale = Tween<double>(begin: 0.985, end: 1).animate(_curve);
    _transition.addStatusListener(_transitionStatusChanged);
    widget.controller.addListener(_handleControllerChanged);

    final initial = widget.initialExternalDocument;
    if (initial != null) {
      _externalDocument = initial;
      _externalRenderer = _prepare(initial);
      _libraryOffstage = true;
      _transition.value = 1;
    }
  }

  @override
  void didUpdateWidget(FolioRoot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
      _handleControllerChanged();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    _transition.duration = reducedMotion ? Duration.zero : AppDurations.normal;
    _transition.reverseDuration = reducedMotion
        ? Duration.zero
        : AppDurations.fast;
  }

  DocumentRenderer? _prepare(DocumentEntry document) {
    ReaderPreloader.prime(
      document: document,
      contentSource: widget.documentContentSource,
    );
    return ReaderPreloader.adopt(
      document,
      contentSource: widget.documentContentSource,
    );
  }

  void _transitionStatusChanged(AnimationStatus status) {
    if (!mounted) {
      return;
    }
    if (status == AnimationStatus.completed &&
        _externalDocument != null &&
        !_closingExternal) {
      if (!_libraryOffstage) {
        setState(() => _libraryOffstage = true);
      }
      return;
    }
    if (status == AnimationStatus.dismissed && _closingExternal) {
      setState(() {
        _externalDocument = null;
        _externalRenderer = null;
        _closingExternal = false;
      });
    }
  }

  /// Takes warm external intents while an external reader is already on the
  /// home route. The library is inactive in that state, so it deliberately
  /// leaves the pending document for this host instead of dropping it.
  void _handleControllerChanged() {
    if (!mounted ||
        _externalDocument == null ||
        widget.controller.pendingDocument == null ||
        !widget.controller.pendingDocumentIsExternal) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _externalDocument == null) {
        return;
      }
      if (!widget.controller.pendingDocumentIsExternal) {
        return;
      }
      final document = widget.controller.takePendingDocument();
      if (document != null) {
        _openExternal(document);
      }
    });
  }

  void _openExternal(DocumentEntry document) {
    if (!mounted) {
      return;
    }
    final replacingExternal = _externalDocument != null;
    FocusManager.instance.primaryFocus?.unfocus();
    final renderer = _prepare(document);
    setState(() {
      _externalDocument = document;
      _externalRenderer = renderer;
      // A repeat intent for the same file must still replace the reader state:
      // otherwise the fresh primed renderer would never be adopted.
      _externalGeneration += 1;
      // Never uncover the library while swapping one external document for
      // another; the swap is immediate so a warm intent does not flash the
      // catalog through the open transition.
      _libraryOffstage = replacingExternal;
      _closingExternal = false;
    });
    if (replacingExternal) {
      _transition.value = 1;
    } else {
      _transition.forward(from: 0);
    }
  }

  void _returnToMain() {
    if (_externalDocument == null || _closingExternal) {
      return;
    }
    _closingExternal = true;
    setState(() => _libraryOffstage = false);
    _transition.reverse();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    _transition.removeStatusListener(_transitionStatusChanged);
    _curve.dispose();
    _transition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final external = _externalDocument;
    final libraryActive = external == null;
    return ColoredBox(
      color: appColors.background,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Offstage(
            offstage: _libraryOffstage,
            child: TickerMode(
              enabled: !_libraryOffstage,
              child: IgnorePointer(
                ignoring: !libraryActive,
                child: ExcludeSemantics(
                  excluding: !libraryActive,
                  child: LibraryScreen(
                    controller: widget.controller,
                    documentContentSource: widget.documentContentSource,
                    active: libraryActive,
                    onOpenExternalDocument: _openExternal,
                  ),
                ),
              ),
            ),
          ),
          if (external != null)
            FadeTransition(
              opacity: _opacity,
              child: ScaleTransition(
                scale: _scale,
                child: IgnorePointer(
                  ignoring: _transition.isAnimating || _closingExternal,
                  child: ReaderScreen(
                    key: ValueKey<String>(
                      'external_reader_${external.id}_$_externalGeneration',
                    ),
                    document: external,
                    contentSource: widget.documentContentSource,
                    openedExternally: true,
                    initialRenderer: _externalRenderer,
                    onReturnToMain: _returnToMain,
                    onRemoveFromRecents: () =>
                        widget.controller.removeFromRecents(external),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
