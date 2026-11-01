import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../logic/reader_state.dart';
import '../logic/office_document_renderer_base.dart';
import '../../widgets/reader_loading_view.dart';

/// Office staged reveal: the platform view stays mounted at opacity 0 while
/// rendering (warming under the Flutter loader), then crossfades with the
/// loader overlay instead of swapping to the WebView's own status text.
///
/// While at opacity 0 the platform view is not painted, so its Android view is
/// not attached to a window yet. Native events must therefore be delivered
/// independently of window attachment (see `OfficePlatformView.emit`), or the
/// `ready` handshake would deadlock.
class OfficeStagedView extends StatefulWidget {
  const OfficeStagedView({required this.renderer, required this.view, super.key});

  final OfficeDocumentRendererBase renderer;
  final Widget view;

  @override
  State<OfficeStagedView> createState() => _OfficeStagedViewState();
}

class _OfficeStagedViewState extends State<OfficeStagedView> {
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
  void didUpdateWidget(OfficeStagedView oldWidget) {
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
