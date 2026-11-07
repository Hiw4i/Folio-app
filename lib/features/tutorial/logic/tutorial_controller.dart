import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../shared/diagnostics/app_log.dart';
import '../../../shared/persistence/coalescing_drainer.dart';
import '../data/tutorial_progress_store.dart';
import '../tutorial_catalog.dart';

/// Tracks learned gestures independently of any reader or visible hint.
class TutorialController extends ChangeNotifier {
  TutorialController({required this._store});

  final TutorialProgressStore _store;
  final _seen = <TutorialTour>{};
  late final _writer = CoalescingDrainer(_save);
  Future<void>? _loading;
  bool _loaded = false;
  bool _disposed = false;

  bool shouldShow(TutorialTour tour) => _loaded && !_seen.contains(tour);

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      // A gesture performed while loading still counts.
      _seen.addAll(await _store.load());
    } catch (error, stack) {
      AppLog.w('Tutorial progress could not be loaded', error, stack);
    }
    _loaded = true;
    _notify();
  }

  void complete(TutorialTour tour) {
    if (_seen.add(tour)) {
      _notify();
      unawaited(_writer.request());
    }
  }

  Future<void> _save() async {
    await load();
    try {
      await _store.save(Set<TutorialTour>.of(_seen));
    } catch (error, stack) {
      AppLog.w('Tutorial progress could not be saved', error, stack);
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
