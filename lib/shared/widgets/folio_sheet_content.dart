import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../settings/folio_settings_scope.dart';
import '../theme/folio_theme.dart';
import 'folio_bottom_sheet.dart';

/// The shared Settings-style surface for [FolioBottomSheet.show].
///
/// Features provide only a title and body. The route owns the backdrop,
/// transitions, outside insets and dismissal; this widget owns the theme,
/// glass, height limit, scrolling, handle and heading.
class FolioSheetContent extends StatelessWidget {
  const FolioSheetContent({
    required this.title,
    required this.child,
    super.key,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final brightness = FolioSettingsScope.isLightThemeOf(context)
        ? Brightness.light
        : Brightness.dark;
    return Theme(
      data: ThemeData(
        brightness: brightness,
        scaffoldBackgroundColor: context.colors.background,
        colorScheme: brightness == Brightness.light
            ? ColorScheme.light(
                primary: context.colors.primary,
                surface: context.colors.background,
              )
            : ColorScheme.dark(
                primary: context.colors.primary,
                surface: context.colors.background,
              ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          // god_mode's sheet surface: a plain solid container. No backdrop
          // filter, rim shader or glass machinery — nothing that could ever
          // let the backdrop bleed through the sheet.
          child: DecoratedBox(
            key: const ValueKey<String>('folio_sheet_surface'),
            decoration: BoxDecoration(
              color: context.glass.opaqueFill,
              borderRadius: BorderRadius.circular(
                FolioBottomSheet.cornerRadius,
              ),
              border: Border.all(color: context.colors.border, width: 0.8),
            ),
            child: SingleChildScrollView(
              padding: AppSpacing.sheetPadding,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Center(
                    child: Container(
                      width: 34,
                      height: 4,
                      margin: EdgeInsets.only(bottom: AppSpacing.xl),
                      decoration: BoxDecoration(
                        color: context.colors.primary.withValues(alpha: 0.33),
                        borderRadius: AppRadius.xsRadius,
                      ),
                    ),
                  ),
                  Center(
                    child: Semantics(
                      header: true,
                      namesRoute: true,
                      child: Text(
                        title.toUpperCase(),
                        semanticsLabel: title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                          color: context.colors.primary,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: AppSpacing.lg),
                  child,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A section heading with the same icon tile and typography in every sheet.
class FolioSheetSectionHeader extends StatelessWidget {
  const FolioSheetSectionHeader({
    required this.icon,
    required this.title,
    this.iconPath,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? iconPath;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Row(
        children: <Widget>[
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: context.colors.primary.withValues(alpha: 0.08),
              borderRadius: AppRadius.mdRadius,
              border: Border.all(color: context.colors.border, width: 0.8),
            ),
            child: iconPath != null
                ? SvgPicture.asset(
                    iconPath!,
                    width: 15,
                    height: 15,
                    colorFilter: ColorFilter.mode(
                      context.colors.primary,
                      BlendMode.srcIn,
                    ),
                  )
                : Icon(icon, size: 15, color: context.colors.primary),
          ),
          SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: context.colors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A group of rows on the shared translucent card surface.
class FolioSheetCard extends StatelessWidget {
  const FolioSheetCard({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.colors.primary.withValues(alpha: 0.05),
        borderRadius: AppRadius.sheetRadius,
        border: Border.all(color: context.colors.border, width: 0.8),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

class FolioSheetDivider extends StatelessWidget {
  const FolioSheetDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 0.8,
      width: double.infinity,
      child: ColoredBox(color: context.colors.border),
    );
  }
}
