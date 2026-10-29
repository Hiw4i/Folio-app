import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/reader/logic/chrome_visibility.dart';

void main() {
  final accumulator = ChromeScrollIntentAccumulator(threshold: 12);

  test('intent accumulates until the hide threshold crosses', () {
    expect(
      accumulator.record(5, visible: true, canHide: true),
      ChromeVisibilityCommand.stay,
    );
    expect(
      accumulator.record(5, visible: true, canHide: true),
      ChromeVisibilityCommand.stay,
    );
    expect(
      accumulator.record(3, visible: true, canHide: true),
      ChromeVisibilityCommand.hide,
    );
  });

  test('a contrary drag resets the accumulated intent', () {
    accumulator.record(10, visible: true, canHide: true);
    expect(
      accumulator.record(-1, visible: true, canHide: true),
      ChromeVisibilityCommand.stay,
    );
    expect(
      accumulator.record(3, visible: true, canHide: true),
      ChromeVisibilityCommand.stay,
    );
  });

  test('the top of the document cannot hide the chrome', () {
    expect(
      accumulator.record(100, visible: true, canHide: false),
      ChromeVisibilityCommand.stay,
    );
    expect(
      accumulator.record(100, visible: true, canHide: false),
      ChromeVisibilityCommand.stay,
    );
  });

  test('scrolling up while hidden accumulates toward show', () {
    expect(
      accumulator.record(-7, visible: false, canHide: true),
      ChromeVisibilityCommand.stay,
    );
    expect(
      accumulator.record(-7, visible: false, canHide: true),
      ChromeVisibilityCommand.show,
    );
  });

  test('scrolling down while hidden never hides again', () {
    expect(
      accumulator.record(30, visible: false, canHide: true),
      ChromeVisibilityCommand.stay,
    );
  });

  test('reset clears a half-recorded intent', () {
    accumulator.record(10, visible: true, canHide: true);
    accumulator.reset();
    expect(
      accumulator.record(3, visible: true, canHide: true),
      ChromeVisibilityCommand.stay,
    );
  });
}
