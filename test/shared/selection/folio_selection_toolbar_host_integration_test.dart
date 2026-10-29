import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/shared/selection/folio_selection_toolbar.dart';

void main() {
  testWidgets('hosted editable menu retains focus during mouse click', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'hello');
    final focus = FocusNode();
    final key = GlobalKey<EditableTextState>();
    var copies = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => FolioSelectionToolbarHost(child: child!),
        home: Center(
          child: SizedBox(
            width: 300,
            child: EditableText(
              key: key,
              controller: controller,
              focusNode: focus,
              style: const TextStyle(),
              cursorColor: Colors.blue,
              backgroundCursorColor: Colors.grey,
              contextMenuBuilder: (context, state) => FolioSelectionToolbar(
                anchors: state.contextMenuAnchors,
                buttonItems: [
                  ContextMenuButtonItem(
                    type: ContextMenuButtonType.copy,
                    onPressed: () => copies++,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pumpAndSettle();
    key.currentState!.userUpdateTextEditingValue(
      controller.value.copyWith(
        selection: const TextSelection(baseOffset: 0, extentOffset: 5),
      ),
      SelectionChangedCause.toolbar,
    );
    await tester.pumpAndSettle();
    expect(key.currentState!.showToolbar(), isTrue);
    await tester.pumpAndSettle();
    final copy = find.byKey(const ValueKey('folio_toolbar_copy'));
    expect(copy, findsOneWidget);
    expect(focus.hasFocus, isTrue);
    final gesture = await tester.startGesture(
      tester.getCenter(copy),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(focus.hasFocus, isTrue);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(copies, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    focus.dispose();
  });
}
