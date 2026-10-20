import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/shared/widgets/folio_status_view.dart';

void main() {
  testWidgets('uses one rhythm for title, message, action and footer', (
    tester,
  ) async {
    const actionKey = ValueKey<String>('status_action');
    const footerKey = ValueKey<String>('status_footer');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 360,
              child: FolioStatusView(
                title: 'Access expired',
                message: 'Folio no longer has permission to read this file.',
                action: const SizedBox(key: actionKey, width: 132, height: 50),
                footer: const SizedBox(key: footerKey, width: 100, height: 20),
              ),
            ),
          ),
        ),
      ),
    );

    final titleRect = tester.getRect(find.text('Access expired'));
    final messageRect = tester.getRect(
      find.text('Folio no longer has permission to read this file.'),
    );
    final actionRect = tester.getRect(find.byKey(actionKey));
    final footerRect = tester.getRect(find.byKey(footerKey));

    expect(
      messageRect.top - titleRect.bottom,
      FolioStatusView.titleMessageSpacing,
    );
    expect(
      actionRect.top - messageRect.bottom,
      FolioStatusView.messageActionSpacing,
    );
    expect(
      footerRect.top - actionRect.bottom,
      FolioStatusView.actionFooterSpacing,
    );
    expect(
      FolioStatusView.messageActionSpacing,
      greaterThan(FolioStatusView.titleMessageSpacing),
    );
  });
}
