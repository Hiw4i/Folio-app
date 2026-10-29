import 'package:flutter_test/flutter_test.dart';
import 'package:folio/shared/diagnostics/app_log.dart';

void main() {
  final lines = <String>[];

  setUp(() {
    lines.clear();
    AppLog.sink = lines.add;
    AppLog.verbose = true;
  });

  tearDown(() {
    AppLog.verbose = false;
  });

  test('errors carry the message, the error object and the stack trace', () {
    final stack = StackTrace.current;
    AppLog.e('Launch probe failed', StateError('boom'), stack);

    final line = lines.single;
    expect(line, contains('Folio[ERROR]'));
    expect(line, contains('Launch probe failed'));
    expect(line, contains('boom'));
    expect(line, contains('app_log_test.dart'));
  });

  test('errors work without a stack trace', () {
    AppLog.e('Save failed', const FormatException('bad'));

    expect(lines.single, contains('Save failed: FormatException: bad'));
  });

  test('warnings always surface', () {
    AppLog.w('Cache read degraded', 'file missing');

    expect(lines.single, contains('Folio[WARN] Cache read degraded: file missing'));
  });

  test('debug lines are suppressed when verbose is off', () {
    AppLog.verbose = false;
    AppLog.d('per-tick noise');

    expect(lines, isEmpty);
  });

  test('debug lines surface when verbose is on', () {
    AppLog.d('per-tick noise');

    expect(lines.single, 'per-tick noise');
  });
}
