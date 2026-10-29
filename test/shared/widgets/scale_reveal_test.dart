import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/shared/widgets/scale_reveal.dart';

void main() {
  testWidgets('an initially hidden surface can release retained content', (
    tester,
  ) async {
    var hidden = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ScaleReveal(
          visible: false,
          onHidden: () => hidden++,
          child: const Text('Copy'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(hidden, 1);
  });

  testWidgets('one motion overshoots on reveal and hides without input', (
    tester,
  ) async {
    final visible = ValueNotifier(false);
    addTearDown(visible.dispose);
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (context, value, _) => ScaleReveal(
            visible: value,
            child: TextButton(
              onPressed: () => taps++,
              child: const Text('Copy'),
            ),
          ),
        ),
      ),
    );
    double scale() => tester
        .widget<Transform>(
          find
              .descendant(
                of: find.byType(ScaleReveal),
                matching: find.byType(Transform),
              )
              .first,
        )
        .transform
        .storage[0];
    expect(scale(), 0);
    visible.value = true;
    await tester.pump();
    var maximum = 0.0;
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (scale() > maximum) maximum = scale();
    }
    expect(maximum, greaterThan(1.01));
    expect(maximum, lessThan(1.06));
    await tester.pumpAndSettle();
    expect(scale(), 1);
    visible.value = false;
    await tester.pump();
    await tester.tap(find.text('Copy'), warnIfMissed: false);
    expect(taps, 0);
    await tester.pumpAndSettle();
    expect(scale(), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reversal preserves continuity and reduced motion snaps', (
    tester,
  ) async {
    final visible = ValueNotifier(false);
    final reduced = ValueNotifier(false);
    addTearDown(visible.dispose);
    addTearDown(reduced.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: Listenable.merge([visible, reduced]),
          builder: (context, _) => MediaQuery(
            data: MediaQueryData(disableAnimations: reduced.value),
            child: ScaleReveal(
              visible: visible.value,
              child: const Text('Copy'),
            ),
          ),
        ),
      ),
    );
    double scale() => tester
        .widget<Transform>(
          find
              .descendant(
                of: find.byType(ScaleReveal),
                matching: find.byType(Transform),
              )
              .first,
        )
        .transform
        .storage[0];
    visible.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final before = scale();
    visible.value = false;
    await tester.pump();
    expect(scale(), closeTo(before, .0001));
    await tester.pumpAndSettle();
    expect(scale(), 0);
    visible.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    reduced.value = true;
    await tester.pump();
    expect(scale(), 1);
    visible.value = false;
    await tester.pump();
    expect(scale(), 0);
    expect(tester.binding.transientCallbackCount, 0);
  });
}
