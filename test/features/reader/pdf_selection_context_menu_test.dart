import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/reader/pdf/widgets/pdf_document_view.dart';

void main() {
  test('PDF menu is directly recognisable as self-positioned by pdfrx', () {
    final menu = PdfSelectionContextMenu(
      primaryAnchor: const Offset(80, 120),
      buttonItems: <ContextMenuButtonItem>[
        ContextMenuButtonItem(
          onPressed: () {},
          type: ContextMenuButtonType.copy,
        ),
      ],
    );
    // This checks the returned widget's type, not a descendant Align. A wrapper
    // here makes pdfrx add a second size-observed Positioned around the toolbar.
    expect(menu, isA<Align>());
    expect(menu.alignment, Alignment.topLeft);
  });

  testWidgets('PDF selection toolbar provides its own Material localization', (
    tester,
  ) async {
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFF000000),
        pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
        ),
        home: PdfSelectionContextMenu(
          primaryAnchor: const Offset(80, 120),
          buttonItems: <ContextMenuButtonItem>[
            ContextMenuButtonItem(
              onPressed: () {},
              type: ContextMenuButtonType.copy,
            ),
          ],
        ),
      ),
    );
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
    }
    expect(
      find.byKey(const ValueKey<String>('folio_toolbar_copy')),
      findsOneWidget,
    );
  });
}
