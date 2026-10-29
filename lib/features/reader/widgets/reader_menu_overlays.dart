import 'package:flutter/widgets.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../../shared/glass/liquid_glass.dart';
import '../../../shared/theme/folio_theme.dart';

/// Expanded exit menu of the reader: the two actions mirror so the most
/// likely one sits on top — externally launched readers most often close the
/// app, in-app readers most often return to the library.
class ReaderExitMenu extends StatelessWidget {
  const ReaderExitMenu({
    required this.openedExternally,
    required this.onReturnToMain,
    required this.onCloseApp,
    super.key,
  });

  final bool openedExternally;
  final VoidCallback onReturnToMain;
  final VoidCallback onCloseApp;

  @override
  Widget build(BuildContext context) {
    final closeApp = _MenuAction(
      label: 'Close app',
      icon: LucideIcons.x,
      onTap: onCloseApp,
    );
    final returnToMain = _MenuAction(
      label: 'Return to main',
      icon: LucideIcons.chevronLeft,
      onTap: onReturnToMain,
    );
    return Padding(
      padding: AppSpacing.settingsRowPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          openedExternally ? closeApp : returnToMain,
          openedExternally ? returnToMain : closeApp,
        ],
      ),
    );
  }
}

/// Expanded document menu: file info and remove-from-recents.
class ReaderMenuContent extends StatelessWidget {
  const ReaderMenuContent({
    required this.onFileInfo,
    required this.onRemove,
    super.key,
  });

  final VoidCallback onFileInfo;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppSpacing.settingsRowPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _MenuAction(label: 'File info', onTap: onFileInfo),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: SizedBox(
              height: 1,
              child: AdaptiveGlassDecoration(
                child: ColoredBox(color: appColors.separator),
              ),
            ),
          ),
          _MenuAction(label: 'Remove from Recents', onTap: onRemove),
        ],
      ),
    );
  }
}

/// Glyph of the collapsed menu button.
class ReaderMenuGlyph extends StatelessWidget {
  const ReaderMenuGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const AdaptiveGlassIcon(LucideIcons.moreVertical, size: 20);
  }
}

class _MenuAction extends StatelessWidget {
  const _MenuAction({required this.label, required this.onTap, this.icon});

  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Row(
                children: <Widget>[
                  if (icon case final icon?) ...<Widget>[
                    AdaptiveGlassIcon(icon, size: 16),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: AdaptiveGlassText(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyStrong(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
