import 'dart:async';

import 'package:flutter/foundation.dart';

import '../diagnostics/app_log.dart';
import '../persistence/coalescing_drainer.dart';
import 'folio_settings.dart';
import 'folio_settings_store.dart';

class FolioSettingsController extends ChangeNotifier {
  FolioSettingsController({required FolioSettingsStore store})
    // ignore: prefer_initializing_formals
    : _store = store;

  final FolioSettingsStore _store;

  /// One writer, latest-value coalescing. A rapid pair of switches cannot
  /// race two temporary files or leave an older preference on disk.
  late final CoalescingDrainer _writer = CoalescingDrainer(_writeSnapshot);

  FolioSettings _settings = const FolioSettings();
  Future<void>? _loading;
  bool _blurChanged = false;
  bool _motionChanged = false;
  bool _navigationChanged = false;
  bool _disposed = false;
  Object? _saveError;

  FolioSettings get settings => _settings;
  bool get hasSaveError => _saveError != null;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final stored = await _store.load();
      // A slow disk read must never undo an interaction already made by the
      // user. Merge untouched fields instead of discarding all stored values.
      final next = stored.copyWith(
        blurEnabled: _blurChanged ? _settings.blurEnabled : null,
        liquidMotionEnabled: _motionChanged
            ? _settings.liquidMotionEnabled
            : null,
        showNavigationOnScrollUp: _navigationChanged
            ? _settings.showNavigationOnScrollUp
            : null,
      );
      if (next != _settings) {
        _settings = next;
        _notify();
      }
    } catch (error, stack) {
      // Missing/corrupt storage is not a reason to block the first app frame.
      AppLog.w('Folio settings could not be loaded', error, stack);
    }
  }

  void setBlurEnabled(bool enabled) {
    if (_disposed || enabled == _settings.blurEnabled) {
      return;
    }
    _blurChanged = true;
    _settings = _settings.copyWith(blurEnabled: enabled);
    _changed();
  }

  void setLiquidMotionEnabled(bool enabled) {
    if (_disposed || enabled == _settings.liquidMotionEnabled) {
      return;
    }
    _motionChanged = true;
    _settings = _settings.copyWith(liquidMotionEnabled: enabled);
    _changed();
  }

  void setShowNavigationOnScrollUp(bool enabled) {
    if (_disposed || enabled == _settings.showNavigationOnScrollUp) {
      return;
    }
    _navigationChanged = true;
    _settings = _settings.copyWith(showNavigationOnScrollUp: enabled);
    _changed();
  }

  void _changed() {
    _saveError = null;
    _notify();
    unawaited(_writer.request());
  }

  void retrySave() {
    if (!_disposed) {
      unawaited(_writer.request());
    }
  }

  Future<void> _writeSnapshot() async {
    await load();
    final snapshot = _settings;
    try {
      await _store.save(snapshot);
      _saveError = null;
    } catch (error, stack) {
      _saveError = error;
      AppLog.w('Folio settings could not be saved', error, stack);
    }
    _notify();
  }

  /// Also useful when the app is backgrounded; pending writes outlive the UI.
  Future<void> flush() => _writer.flush();

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
