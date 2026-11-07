import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../glass/surface/liquid_surface.dart';
import '../../settings/folio_settings_scope.dart';
import '../../theme/folio_theme.dart';
import 'info_notice_layout.dart';
import 'info_notice_shape.dart';

/// A visible, non-interactive notice anchored to the widget it wraps.
/// Uses GOD Mode's overlay layout, measured text and continuous caret shape.
class InfoNoticeTooltip extends StatefulWidget {
  const InfoNoticeTooltip({
    required this.message,
    required this.child,
    super.key,
  });

  final String message;
  final Widget child;

  @override
  State<InfoNoticeTooltip> createState() => _InfoNoticeTooltipState();
}

class _InfoNoticeTooltipState extends State<InfoNoticeTooltip> {
  static const _maxWidth = 320.0;
  static const _padding = EdgeInsets.symmetric(
    horizontal: AppSpacing.lg,
    vertical: AppSpacing.md,
  );

  final _portal = OverlayPortalController()..show();

  @override
  Widget build(BuildContext context) => OverlayPortal.overlayChildLayoutBuilder(
    controller: _portal,
    overlayChildBuilder: _buildOverlay,
    child: widget.child,
  );

  Widget _buildOverlay(BuildContext context, OverlayChildLayoutInfo info) {
    final anchor = MatrixUtils.transformRect(
      info.childPaintTransform,
      Offset.zero & info.childSize,
    );
    final viewport = _viewport(context, info.overlaySize);
    if (anchor.isEmpty || !viewport.contains(anchor.center)) {
      return const SizedBox.shrink();
    }
    final widthLimit = math.min(
      _maxWidth,
      InfoNoticeLayout.availableBounds(viewport, anchor).width,
    );
    if (widthLimit <= _padding.horizontal) {
      return const SizedBox.shrink();
    }

    final media = MediaQuery.of(context);
    final style = AppTextStyles.body(context).copyWith(
      inherit: false,
      fontWeight: media.boldText ? FontWeight.bold : null,
    );
    final painter = TextPainter(
      text: TextSpan(text: widget.message, style: style),
      textAlign: TextAlign.center,
      textDirection: Directionality.of(context),
      textScaler: media.textScaler,
      locale: Localizations.maybeLocaleOf(context),
    );
    late final Size desiredSize;
    try {
      painter.layout(maxWidth: widthLimit - _padding.horizontal);
      final width = math.min(
        widthLimit,
        painter.width.ceilToDouble() + _padding.horizontal,
      );
      painter.layout(maxWidth: width - _padding.horizontal);
      desiredSize = Size(
        width,
        painter.height.ceilToDouble() +
            _padding.vertical +
            InfoNoticeLayout.caretHeight,
      );
    } finally {
      painter.dispose();
    }
    final layout = InfoNoticeLayout.resolve(
      viewport: viewport,
      anchor: anchor,
      desiredSize: desiredSize,
    );
    if (layout == null) {
      return const SizedBox.shrink();
    }

    final shape = InfoNoticeShape(
      pointerX: layout.pointerX,
      below: layout.below,
      borderRadius: AppRadius.lg,
      side: BorderSide(color: context.colors.border),
    );
    final blur = FolioSettingsScope.blurEnabledOf(context);
    final glass = context.glass;
    Widget bubble = DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        color: blur ? glass.surfaceFill : glass.opaqueFill,
      ),
      child: Padding(
        padding: layout.caretPadding.add(_padding),
        child: Text(
          widget.message,
          style: style,
          textAlign: TextAlign.center,
          overflow: TextOverflow.clip,
        ),
      ),
    );
    if (blur) {
      bubble = ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        child: BackdropFilter(filter: LiquidBlur.filter, child: bubble),
      );
    }
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned.fromRect(
            rect: layout.rect,
            child: Semantics(container: true, liveRegion: true, child: bubble),
          ),
        ],
      ),
    );
  }

  Rect _viewport(BuildContext context, Size overlaySize) {
    // SafeArea may have consumed local padding. Use raw view insets and
    // convert them to the same overlay coordinates as the anchor.
    final view = MediaQueryData.fromView(View.of(context));
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final safe = Rect.fromLTRB(
      math.max(view.viewPadding.left, view.viewInsets.left),
      math.max(view.viewPadding.top, view.viewInsets.top),
      view.size.width - math.max(view.viewPadding.right, view.viewInsets.right),
      view.size.height -
          math.max(view.viewPadding.bottom, view.viewInsets.bottom),
    );
    return (Offset.zero & overlaySize).intersect(
      Rect.fromPoints(
        overlay.globalToLocal(safe.topLeft),
        overlay.globalToLocal(safe.bottomRight),
      ),
    );
  }
}
