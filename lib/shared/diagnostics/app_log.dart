import 'package:flutter/foundation.dart';

/// Sink for one formatted log line. Injectable so tests can capture output.
typedef AppLogSink = void Function(String line);

/// Single logging facade for Folio.
///
/// Debug chatter ([d]) is compiled out of release builds; warnings and errors
/// always surface and always carry their error object and stack trace. A
/// `catch` clause that neither logs nor rethrows is a bug, not a style.
abstract final class AppLog {
  static AppLogSink sink = _defaultSink;

  /// Chatty per-event logging; enabled only in debug builds.
  static bool verbose = kDebugMode;

  static void d(String message) {
    if (verbose) {
      sink(message);
    }
  }

  static void w(String message, [Object? error, StackTrace? stackTrace]) {
    sink(_compose('WARN', message, error, stackTrace));
  }

  static void e(String message, Object error, [StackTrace? stackTrace]) {
    sink(_compose('ERROR', message, error, stackTrace));
  }

  static String _compose(
    String level,
    String message,
    Object? error,
    StackTrace? stackTrace,
  ) {
    final line = StringBuffer('Folio[$level] $message');
    if (error != null) {
      line.write(': $error');
    }
    if (stackTrace != null) {
      line
        ..writeln()
        ..write(stackTrace);
    }
    return line.toString();
  }

  static void _defaultSink(String line) {
    debugPrint(line);
  }
}
