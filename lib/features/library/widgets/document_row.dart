import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../shared/theme/folio_theme.dart';
import '../../../shared/utils/file_format.dart' show formatFileSize;
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
          scale: _pressed ? 0.986 : 1,
          duration: AppMotion.resolve(context, AppDurations.fastest),
          curve: AppCurves.emphasized,
          alignment: Alignment.center,
          child: AnimatedContainer(
            duration: AppMotion.resolve(context, AppDurations.fastest),
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
                          style: AppTextStyles.body(context),
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
                        style: AppTextStyles.metadata(context),
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
        color: context.colors.primary.withValues(alpha: 0.044),
        borderRadius: AppRadius.controlRadius,
        border: Border.all(color: context.colors.border, width: 0.8),
      ),
      alignment: Alignment.center,
      child: format.iconPath != null
          ? SvgPicture.asset(
              format.iconPath!,
              width: 24,
              height: 24,
              colorFilter: ColorFilter.mode(
                context.colors.primary.withValues(alpha: 0.88),
                BlendMode.srcIn,
              ),
            )
          : Icon(
              format.icon,
              size: 24,
              color: context.colors.primary.withValues(alpha: 0.88),
            ),
    );
  }
}
