import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:folio/shared/persistence/coalescing_drainer.dart';

void main() {
  test('requests arriving during one drain re-arm exactly once', () async {
    var drains = 0;
    final drainer = CoalescingDrainer(() async {
      drains++;
      await Future<void>.delayed(Duration.zero);
    });
    unawaited(drainer.request());
    // All of these arrive while the first drain is still running; they must
    // coalesce into a single re-arm, not one drain each.
    unawaited(drainer.request());
    unawaited(drainer.request());
    await drainer.flush();
    expect(drains, 2);
  });

  test('drains never overlap', () async {
    var active = 0;
    var maxActive = 0;
    var drains = 0;
    late final CoalescingDrainer drainer;
    drainer = CoalescingDrainer(() async {
      drains++;
      active++;
      if (active > maxActive) {
        maxActive = active;
      }
      await Future<void>.delayed(Duration.zero);
      active--;
      if (drains < 5) {
        unawaited(drainer.request());
      }
    });
    unawaited(drainer.request());
    await drainer.flush();
    expect(maxActive, 1);
    expect(drains, 5);
  });

  test('flush resolves only after the pending work is done', () async {
    var written = false;
    final drainer = CoalescingDrainer(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      written = true;
    });
    unawaited(drainer.request());
    await drainer.flush();
    expect(written, isTrue);
  });
}
