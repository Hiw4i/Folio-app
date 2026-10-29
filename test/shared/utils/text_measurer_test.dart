import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/shared/utils/text_measurer.dart';

const _style = TextStyle(fontSize: 14, fontFamily: 'Test');

void main() {
  test('measures a positive width and repeats it from cache', () {
    final measurer = BoundedTextMeasurer();
    final width = measurer.widthOf(
      'Hello',
      style: _style,
      direction: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    );
    expect(width, greaterThan(0));
    expect(
      measurer.widthOf(
        'Hello',
        style: _style,
        direction: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
      ),
      width,
    );
    expect(measurer.size, 1);
  });

  test('distinct inputs occupy distinct entries', () {
    final measurer = BoundedTextMeasurer();
    double measure(String text, double fontSize) => measurer.widthOf(
      text,
      style: TextStyle(fontSize: fontSize),
      direction: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    );
    measure('A', 14);
    measure('B', 14);
    measure('A', 15);
    expect(measurer.size, 3);
  });

  test('capacity evicts wholesale', () {
    final measurer = BoundedTextMeasurer(capacity: 2);
    double measure(String text) => measurer.widthOf(
      text,
      style: _style,
      direction: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    );
    measure('one');
    measure('two');
    measure('three');
    expect(measurer.size, 1);
  });
}
