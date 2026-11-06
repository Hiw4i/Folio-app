import 'package:flutter/widgets.dart';

import '../../logic/document_renderer.dart';
import '../../logic/reader_navigation.dart';

/// Normalized surface events the reader shell consumes. Format views speak
/// their own event languages; each binding translates them into these three.
class ReaderSurfaceCallbacks {
  const ReaderSurfaceCallbacks({
    required this.onContentTap,
    required this.onReadingDrag,
    required this.onSelectionChanged,
  });

  /// An already-classified content tap (chrome toggle candidate).
  final VoidCallback onContentTap;

  /// A real user vertical drag over the document. `canHide` says whether the
  /// drag may hide the chrome (flings, search reveals and programmatic moves
  /// must not arrive here).
  final void Function(double delta, bool canHide) onReadingDrag;

  /// Selection active/inactive — the shell blocks chrome hide/toggle while
  /// a selection exists, on every format.
  final ValueChanged<bool> onSelectionChanged;
}

/// Per-format interaction differences the shell must respect. Everything the
/// surfaces can normalize away stays out of this class.
class ReaderInteractionPolicy {
  const ReaderInteractionPolicy({required this.scrollControlsChrome});

  /// Whether scrolling the document may hide the chrome. PPTX pages flip at
  /// the edges instead of scrolling, so its scroll never drives chrome.
  final bool scrollControlsChrome;
}

/// The UI adapter between the reader shell and one format surface.
///
/// A binding is NOT a second renderer: it owns UI-side resources (navigation
/// adapters, scroll controllers, percent projection), projects renderer state
/// through [navigation], and builds the format surface. It never closes or
/// disposes the renderer — the screen's lifecycle helper owns that.
abstract interface class ReaderBinding {
  DocumentRenderer get renderer;

  ReaderNavigation get navigation;

  ReaderInteractionPolicy get interactionPolicy;

  /// Whether the format surface currently hosts its own overlay that must
  /// consume Back presses and hide the reading chrome (the PPTX slide
  /// overview). Formats without document-hosted overlays report false.
  bool get hasSurfaceOverlay;

  /// Closes that overlay. Returns true when something was actually closed,
  /// so the shell can consume the Back press.
  bool closeSurfaceOverlay();

  /// Builds the format surface wired to [callbacks]. Called once per screen
  /// mounting; repeated builds must not recreate owned resources.
  Widget buildSurface(ReaderSurfaceCallbacks callbacks);

  /// Releases the binding's own UI resources. Never disposes the renderer.
  void dispose();
}
