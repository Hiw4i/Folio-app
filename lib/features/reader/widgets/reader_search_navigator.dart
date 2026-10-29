import 'package:flutter/widgets.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../../shared/glass/liquid_glass.dart';
import '../../../shared/theme/folio_theme.dart';
import '../../../shared/utils/text_measurer.dart';
import '../logic/document_renderer.dart';

/// Search hit navigation pill shown above the reader chrome while a query is
/// active. Sizing around the label is measured up front because the liquid
/// surface gives the shadow an oversized paint box; the Row must stay tight
/// to the material dimensions or it drifts out of the pill.
class ReaderSearchNavigator extends StatelessWidget {
  const ReaderSearchNavigator({required this.renderer, super.key});

  final DocumentRenderer renderer;

  static TextStyle _labelStyle(BuildContext context) => TextStyle(
    fontFamily: 'Inter',
    color: appColors.textPrimary,
    fontSize: 12.5,
    fontWeight: FontWeight.w500,
  );
  static const double _height = 46;
  static const double _leftPadding = 15;
  static const double _rightPadding = 6;
  static const double _gap = 8;
  static const double _buttonWidth = 34;

  /// This widget rebuilds on every renderer notify (each keystroke/page
  /// change); labels are a tiny closed set (`Searching…`, `No matches`,
  /// `N of M`), so cache the measured text width.
  static final BoundedTextMeasurer _labelMeasurer = BoundedTextMeasurer(
    capacity: 64,
  );

  @override
  Widget build(BuildContext context) {
    final currentRenderer = renderer;
    final label = currentRenderer.isSearching
        ? 'Searching…'
        : currentRenderer is PdfDocumentRenderer &&
              currentRenderer.hasNoSearchableText
        ? 'No searchable text'
        : currentRenderer is OfficeDocumentRendererBase &&
              currentRenderer.hasNoSearchableText
        ? 'No searchable text'
        : currentRenderer.hitCount == 0
        ? 'No matches'
        : '${currentRenderer.activeHitIndex + 1} of ${currentRenderer.hitCount}';
    final labelWidth = _labelMeasurer.widthOf(
      label,
      style: _labelStyle(context),
      direction: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
    final width =
        _leftPadding + labelWidth + _gap + _buttonWidth * 2 + _rightPadding + 4;
    return LiquidGlass.fixed(
      key: const ValueKey<String>('reader_search_navigator_glass'),
      size: Size(width, _height),
      child: SizedBox(
        width: width,
        height: _height,
        child: Padding(
          padding: const EdgeInsets.only(
            left: _leftPadding,
            right: _rightPadding,
          ),
          child: Row(
            children: <Widget>[
              AdaptiveGlassText(
                key: const ValueKey<String>('reader_search_count'),
                label,
                style: _labelStyle(context),
              ),
              const SizedBox(width: _gap),
              _SearchStepButton(
                key: const ValueKey<String>('reader_previous_hit'),
                label: 'Previous match',
                icon: LucideIcons.chevronUp,
                enabled: currentRenderer.hitCount > 0,
                onTap: currentRenderer.showPreviousHit,
              ),
              _SearchStepButton(
                key: const ValueKey<String>('reader_next_hit'),
                label: 'Next match',
                icon: LucideIcons.chevronDown,
                enabled: currentRenderer.hitCount > 0,
                onTap: currentRenderer.showNextHit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchStepButton extends StatelessWidget {
  const _SearchStepButton({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onTap,
    super.key,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: ReaderSearchNavigator._buttonWidth,
      height: ReaderSearchNavigator._height,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label,
        onTap: enabled ? onTap : null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? onTap : null,
          child: Center(
            child: AdaptiveGlassEffects(
              opacity: enabled ? 1 : 0.38,
              child: AdaptiveGlassIcon(icon, size: 16),
            ),
          ),
        ),
      ),
    );
  }
}
