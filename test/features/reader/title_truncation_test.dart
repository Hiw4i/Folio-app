import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/reader/logic/title_truncation.dart';

const _style = TextStyle(fontSize: 14, fontFamily: 'Test');

void main() {
  final truncator = TitleTruncator();
  const direction = TextDirection.ltr;
  const scaler = TextScaler.noScaling;

  String truncate(String name, double maxWidth) =>
      truncator.truncate(name, _style, maxWidth, direction, scaler);

  test('a fitting name is returned untouched', () {
    final name = 'report.pdf';
    final width = truncator.truncate(
      name,
      _style,
      10000,
      direction,
      scaler,
    );
    expect(width, name);
  });

  test('a non-fitting name keeps its extension readable', () {
    final name = 'Длинное название документа о психике.pdf';
    final result = truncate(name, 160);
    expect(result, isNot(name));
    // The extension stays readable via the `...pdf` suffix form.
    expect(result, endsWith('.pdf'));
    expect(result, startsWith('Длинн'));
    expect(result, contains('...'));
  });

  test('names without an extension fall back to an end ellipsis', () {
    final result = truncate('БезРасширенияОченьДлинноеИмяФайла', 90);
    expect(result, endsWith('…'));
    expect(result, isNot(contains('.')));
  });

  test('a dot at the start is not treated as an extension', () {
    final result = truncate('.hidden-file-with-a-very-long-name', 80);
    expect(result, endsWith('…'));
  });

  test('extreme narrowness shrinks to the ellipsis', () {
    expect(truncate('anything.pdf', 0), '…');
    expect(truncate('anything.pdf', -5), '…');
  });

  test('repeated truncation is stable (cache correctness)', () {
    const name = 'Очень длинное имя документа для чтения.txt';
    final first = truncate(name, 140);
    final second = truncate(name, 140);
    expect(second, first);
  });
}
