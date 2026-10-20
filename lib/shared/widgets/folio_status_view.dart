import 'package:flutter/widgets.dart';

import '../theme/folio_theme.dart';

/// Shared title → message → action rhythm for empty, error and permission
/// states.
///
/// Every status surface composes this widget instead of rebuilding its own
/// column, so a single spacing change here updates all of them together.
class FolioStatusView extends StatelessWidget {
  const FolioStatusView({
    required this.message,
    this.title,
    this.action,
    this.footer,
    this.titleStyle,
    this.messageStyle,
    this.messagePadding = EdgeInsets.zero,
    this.textAlign = TextAlign.center,
    this.crossAxisAlignment = CrossAxisAlignment.center,
    super.key,
  });

  /// Gap between the title and the message.
  static const double titleMessageSpacing = AppSpacing.md;

  /// Gap between the message and the primary action. Kept deliberately larger
  /// than [titleMessageSpacing] so a glass button never crowds the copy.
  static const double messageActionSpacing = AppSpacing.xxl;

  /// Gap between the primary action and an optional secondary action.
  static const double actionFooterSpacing = AppSpacing.md;

  final String? title;
  final String message;
  final Widget? action;
  final Widget? footer;
  final TextStyle? titleStyle;
  final TextStyle? messageStyle;
  final EdgeInsetsGeometry messagePadding;
  final TextAlign textAlign;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: crossAxisAlignment,
      children: <Widget>[
        if (title != null) ...<Widget>[
          Text(
            title!,
            textAlign: textAlign,
            style: titleStyle ?? AppTextStyles.subheading(context),
          ),
          const SizedBox(height: titleMessageSpacing),
        ],
        Padding(
          padding: messagePadding,
          child: Text(
            message,
            textAlign: textAlign,
            style: messageStyle ?? AppTextStyles.metadata(context),
          ),
        ),
        if (action != null) ...<Widget>[
          const SizedBox(height: messageActionSpacing),
          action!,
        ],
        if (footer != null) ...<Widget>[
          const SizedBox(height: actionFooterSpacing),
          footer!,
        ],
      ],
    );
  }
}
