import '../../../library/data/document_entry.dart';
import '../../office/logic/office_document_renderer_base.dart';

class WordDocumentRenderer extends OfficeDocumentRendererBase {
  WordDocumentRenderer({
    required super.document,
    required super.gateway,
    super.prepareTimeout,
    super.readyTimeout,
  }) : assert(document.format == DocumentFormat.docx);
}
