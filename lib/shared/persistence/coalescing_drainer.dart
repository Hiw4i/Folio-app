import 'dart:async';

/// Single-writer, latest-value coalescing queue.
///
/// Many requesters, one drain: [request] marks work as pending and starts the
/// drain loop if idle. The loop keeps consuming the pending flag, so requests
/// arriving mid-drain fold into the same run, and a request arriving between
/// drain completion and shutdown re-arms the loop exactly once. Owners of
/// this pattern — settings persistence and the library catalog cache — must
/// never run two writes concurrently, and the latest request must always win.
class CoalescingDrainer {
  CoalescingDrainer(this._drain);

  final Future<void> Function() _drain;

  Future<void>? _running;
  bool _requested = false;

  /// Marks one unit of work and starts the drain loop if it is idle. The
  /// returned future belongs to the currently running loop; most callers
  /// ignore it and use [flush] instead.
  Future<void> request() {
    _requested = true;
    return _running ??= _run();
  }

  Future<void> _run() async {
    try {
      while (_requested) {
        _requested = false;
        await _drain();
      }
    } finally {
      _running = null;
      // A request may arrive in the microtask between draining and shutdown;
      // it must not be lost.
      if (_requested) {
        unawaited(request());
      }
    }
  }

  /// Resolves only after every requested unit of work has been drained.
  Future<void> flush() async {
    while (true) {
      final running = _running;
      if (running == null) {
        return;
      }
      await running;
    }
  }
}
