import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/library/widgets/document_row.dart';

void main() {
  testWidgets('a narrow library row keeps the extension and full spoken name', (
    tester,
  ) async {
    const name = 'Government research report with a very long title.pdf';
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFF000000),
        builder: (context, child) => Center(
          child: SizedBox(
            width: 260,
            child: DocumentRow(
              document: DocumentEntry(
                id: name,
                source: const FileDocumentSource(name),
                name: name,
                format: DocumentFormat.pdf,
                sizeBytes: 1024,
                modifiedAt: DateTime.utc(2026),
              ),
              onTap: () {},
            ),
          ),
        ),
      ),
    );

    final label = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.semanticsLabel == name,
      ),
    );
    expect(label.data, matches(r'^Gov.*\.\.\.pdf$'));
    expect(label.semanticsLabel, name);
  });
}
