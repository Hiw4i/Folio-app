import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../shared/theme/folio_theme.dart';
import '../data/document_entry.dart';

class DocumentRow extends StatefulWidget {
  const DocumentRow({
    required this.document,
    required this.onTap,
    this.onTapDown,
    super.key,
  });

  final DocumentEntry document;
  final VoidCallback onTap;
  final VoidCallback? onTapDown;

  @override
  State<DocumentRow> createState() => _DocumentRowState();
}

class _DocumentRowState extends State<DocumentRow> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) {
      setState(() => _pressed = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final document = widget.document;
    return Semantics(
      button: true,
      label: '${document.name}, ${formatFileSize(document.sizeBytes)}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {
          _setPressed(true);
          widget.onTapDown?.call();
        },
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) => _setPressed(false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed && !reducedMotion ? 0.986 : 1,
          duration: reducedMotion
              ? Duration.zero
              : AppDurations.fastest,
          curve: Curves.easeOutCubic,
          alignment: Alignment.center,
          child: AnimatedContainer(
            duration: reducedMotion
                ? Duration.zero
                : AppDurations.fastest,
            color: _pressed ? const Color(0x0FFFFFFF) : const Color(0x00000000),
            padding: AppSpacing.documentRowPadding,
            child: SizedBox(
              height: 56,
              child: Row(
                children: <Widget>[
                  _FormatGlyph(format: document.format),
                  SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          document.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.filename(context),
                        ),
                        SizedBox(height: AppSpacing.xs),
                        Text(
                          formatFileSize(document.sizeBytes),
                          style: AppTextStyles.metadata(context),
                        ),
                      ],
                    ),
                  ),
                  if (!document.isAvailable)
                    Padding(
                      padding: EdgeInsets.only(left: AppSpacing.md),
                      child: Text(
                        'Unavailable',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          color: appColors.textTertiary,
                          fontSize: 11,
                        ),
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

class _FormatGlyph extends StatelessWidget {
  const _FormatGlyph({required this.format});

  final DocumentFormat format;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: const Color(0x0BFFFFFF),
        borderRadius: AppRadius.controlRadius,
        border: Border.all(color: const Color(0x1FFFFFFF), width: 0.8),
      ),
      alignment: Alignment.center,
      child: format.iconPath != null
          ? SvgPicture.asset(
              format.iconPath!,
              width: 24,
              height: 24,
              colorFilter: ColorFilter.mode(
                appColors.textPrimary.withValues(alpha: 0.88),
                BlendMode.srcIn,
              ),
            )
          : Icon(
              format.icon,
              size: 24,
              color: appColors.textPrimary.withValues(alpha: 0.88),
            ),
    );
  }
}

String formatFileSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(bytes < 10240 ? 1 : 0)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
