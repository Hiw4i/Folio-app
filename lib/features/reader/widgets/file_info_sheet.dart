import 'package:flutter/widgets.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../../shared/theme/folio_theme.dart';
import '../../../shared/utils/file_format.dart';
import '../../../shared/widgets/folio_bottom_sheet.dart';
import '../../../shared/widgets/folio_sheet_content.dart';
import '../../library/data/document_entry.dart';

Future<void> showFolioFileInfoSheet(
  BuildContext context, {
  required DocumentEntry document,
}) async {
  await FolioBottomSheet.show<void>(
    context: context,
    builder: (context) => FileInfoSheet(document: document),
  );
}

/// File metadata only; presentation and motion are shared with Settings.
class FileInfoSheet extends StatelessWidget {
  const FileInfoSheet({required this.document, super.key});

  final DocumentEntry document;

  @override
  Widget build(BuildContext context) {
    return FolioSheetContent(
      title: 'File info',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          FolioSheetSectionHeader(
            icon: document.format.icon,
            iconPath: document.format.iconPath,
            title: 'Details',
          ),
          const SizedBox(height: 10),
          FolioSheetCard(
            children: <Widget>[
              _FileInfoRow(label: 'Name', value: document.name),
              const FolioSheetDivider(),
              _FileInfoRow(
                label: 'Format',
                value: document.format.extension.toUpperCase(),
              ),
              const FolioSheetDivider(),
              _FileInfoRow(
                label: 'Size',
                value: formatFileSize(document.sizeBytes),
              ),
            ],
          ),
          const SizedBox(height: 22),
          const FolioSheetSectionHeader(
            icon: LucideIcons.clock,
            title: 'Dates',
          ),
          const SizedBox(height: 10),
          FolioSheetCard(
            children: <Widget>[
              _FileInfoRow(
                label: 'Created',
                value: formatDocumentDate(document.effectiveCreatedAt),
              ),
              const FolioSheetDivider(),
              _FileInfoRow(
                label: 'Modified',
                value: formatDocumentDate(document.modifiedAt),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FileInfoRow extends StatelessWidget {
  const _FileInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Padding(
        padding: AppSpacing.settingsRowPadding,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Do not squeeze long filenames or scaled labels into two tiny
            // columns on a phone. Every value remains fully readable.
            final stacked =
                constraints.maxWidth < 240 ||
                MediaQuery.textScalerOf(context).scale(15) > 20;
            if (stacked) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(label, style: AppTextStyles.body(context)),
                  SizedBox(height: AppSpacing.xs),
                  Text(value, style: AppTextStyles.metadata(context)),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // Label hugs its content; the value takes all remaining
                // width so long filenames wrap as late as possible.
                Text(label, style: AppTextStyles.body(context)),
                SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Text(
                    value,
                    textAlign: TextAlign.end,
                    style: AppTextStyles.metadata(context),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
