import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:folio/shared/persistence/atomic_file.dart';
import 'package:folio/shared/settings/folio_settings.dart';
import 'package:folio/shared/settings/folio_settings_controller.dart';
import 'package:folio/shared/settings/folio_settings_store.dart';

import '../../support/memory_settings_store.dart';

void main() {
  test('defaults disable blur by default', () {
    const settings = FolioSettings();
    expect(settings.blurEnabled, isFalse);
    expect(settings.liquidMotionEnabled, isTrue);
    expect(settings.showNavigationOnScrollUp, isTrue);
  });

  test('JSON preserves independent switches and tolerates invalid fields', () {
    const settings = FolioSettings(blurEnabled: true);
    expect(FolioSettings.fromJson(settings.toJson()), settings);
    expect(
      FolioSettings.fromJson(<String, Object?>{
        'blurEnabled': 'false',
        'liquidMotionEnabled': false,
      }),
      const FolioSettings(liquidMotionEnabled: false),
    );
    expect(
      FolioSettings.fromJson(<String, Object?>{}).blurEnabled,
      isFalse,
    );
  });

  test('navigation preference round-trips independently of visual effects', () {
    for (final blur in <bool>[true, false]) {
      for (final motion in <bool>[true, false]) {
        for (final navigation in <bool>[true, false]) {
          final settings = FolioSettings(
            blurEnabled: blur,
            liquidMotionEnabled: motion,
            showNavigationOnScrollUp: navigation,
          );
          expect(FolioSettings.fromJson(settings.toJson()), settings);
          expect(settings.copyWith(), settings);
          expect(
            settings.copyWith(showNavigationOnScrollUp: !navigation),
            isNot(settings),
          );
          expect(
            settings.copyWith(blurEnabled: !blur).showNavigationOnScrollUp,
            navigation,
          );
        }
      }
    }
  });

  test('older and malformed navigation fields preserve the old default', () {
    for (final value in <Object?>[null, 'false', 0, <String>[]]) {
      expect(
        FolioSettings.fromJson(<String, Object?>{
          'showNavigationOnScrollUp': value,
        }).showNavigationOnScrollUp,
        isTrue,
      );
    }
    expect(FolioSettings.fromJson(<String, Object?>{}), const FolioSettings());
  });

  test('startup load preserves an already changed navigation preference', () async {
    final store = _ControlledStore();
    final controller = FolioSettingsController(store: store);
    addTearDown(controller.dispose);
    final loading = controller.load();
    controller.setShowNavigationOnScrollUp(false);
    store.loaded.complete(const FolioSettings(
      blurEnabled: false,
      liquidMotionEnabled: false,
    ));
    await loading;
    await controller.flush();
    expect(controller.settings, const FolioSettings(
      blurEnabled: false,
      liquidMotionEnabled: false,
      showNavigationOnScrollUp: false,
    ));
    expect(store.written.last, controller.settings);
  });

  test('changing an effect during load still restores stored navigation', () async {
    final store = _ControlledStore();
    final controller = FolioSettingsController(store: store);
    addTearDown(controller.dispose);
    final loading = controller.load();
    controller.setBlurEnabled(true);
    store.loaded.complete(const FolioSettings(showNavigationOnScrollUp: false));
    await loading;
    await controller.flush();
    expect(controller.settings, const FolioSettings(
      blurEnabled: true,
      showNavigationOnScrollUp: false,
    ));
    expect(store.written.last, controller.settings);
  });

  test('navigation changes persist across a new controller instance', () async {
    final store = MemorySettingsStore();
    final first = FolioSettingsController(store: store);
    await first.load();
    first.setShowNavigationOnScrollUp(false);
    await first.flush();
    first.dispose();
    final second = FolioSettingsController(store: store);
    addTearDown(second.dispose);
    await second.load();
    expect(second.settings, const FolioSettings(showNavigationOnScrollUp: false));
    second.setShowNavigationOnScrollUp(false);
    await second.flush();
    expect(store.saves, 1);
  });

  test('navigation writes are serialized and retain the latest setting', () async {
    final store = _ControlledStore()..blockFirstSave = true;
    store.loaded.complete(const FolioSettings());
    final controller = FolioSettingsController(store: store);
    addTearDown(controller.dispose);
    await controller.load();
    controller.setShowNavigationOnScrollUp(false);
    await store.firstWriteStarted.future;
    controller.setShowNavigationOnScrollUp(true);
    controller.setBlurEnabled(true);
    store.firstWriteFinished.complete();
    await controller.flush();
    expect(store.maxConcurrentWrites, 1);
    expect(store.written.last, const FolioSettings(blurEnabled: true));
  });

  test('disk load cannot undo user interaction during startup', () async {
    final store = _ControlledStore();
    final controller = FolioSettingsController(store: store);
    addTearDown(controller.dispose);
    final loading = controller.load();
    controller.setBlurEnabled(true);
    store.loaded.complete(const FolioSettings(liquidMotionEnabled: false));
    await loading;
    await controller.flush();
    expect(
      controller.settings,
      const FolioSettings(blurEnabled: true, liquidMotionEnabled: false),
    );
    expect(store.written.last, controller.settings);
  });

  test(
    'saves are serialized and eventually persist the latest value',
    () async {
      final store = _ControlledStore()..blockFirstSave = true;
      store.loaded.complete(const FolioSettings());
      final controller = FolioSettingsController(store: store);
      addTearDown(controller.dispose);
      await controller.load();
      controller.setBlurEnabled(true);
      await store.firstWriteStarted.future;
      controller.setLiquidMotionEnabled(false);
      controller.setBlurEnabled(false);
      expect(store.maxConcurrentWrites, 1);
      store.firstWriteFinished.complete();
      await controller.flush();
      expect(store.maxConcurrentWrites, 1);
      expect(
        store.written.last,
        const FolioSettings(liquidMotionEnabled: false),
      );
    },
  );

  test('save failure keeps live preferences and supports retry', () async {
    final store = _ControlledStore()..failWrites = true;
    store.loaded.complete(const FolioSettings());
    final controller = FolioSettingsController(store: store);
    addTearDown(controller.dispose);
    await controller.load();
    controller.setBlurEnabled(true);
    await controller.flush();
    expect(controller.settings.blurEnabled, isTrue);
    expect(controller.hasSaveError, isTrue);
    store.failWrites = false;
    controller.retrySave();
    await controller.flush();
    expect(controller.hasSaveError, isFalse);
    expect(store.written.last.blurEnabled, isTrue);
  });

  test(
    'pending persistence finishes without notification after disposal',
    () async {
      final store = _ControlledStore();
      final controller = FolioSettingsController(store: store);
      controller.setBlurEnabled(true);
      controller.dispose();
      store.loaded.complete(const FolioSettings());
      await controller.flush();
      expect(store.written.single.blurEnabled, isTrue);
      controller.setLiquidMotionEnabled(false);
      expect(controller.settings.liquidMotionEnabled, isTrue);
    },
  );

  test('same value does not schedule a write', () async {
    final store = MemorySettingsStore();
    final controller = FolioSettingsController(store: store);
    addTearDown(controller.dispose);
    await controller.load();
    controller.setBlurEnabled(false);
    await controller.flush();
    expect(store.saves, 0);
  });

  test('new controller restores switches saved by previous instance', () async {
    final directory = await Directory.systemTemp.createTemp('folio-settings-');
    addTearDown(() => directory.delete(recursive: true));
    final store = FileFolioSettingsStore(
      directoryProvider: () async => directory,
    );
    expect(await store.load(), const FolioSettings());
    final first = FolioSettingsController(store: store);
    await first.load();
    first.setBlurEnabled(true);
    first.setLiquidMotionEnabled(false);
    first.setShowNavigationOnScrollUp(false);
    await first.flush();
    first.dispose();
    final second = FolioSettingsController(store: store);
    addTearDown(second.dispose);
    await second.load();
    expect(
      second.settings,
      const FolioSettings(
        blurEnabled: true,
        liquidMotionEnabled: false,
        showNavigationOnScrollUp: false,
      ),
    );
    expect(
      await File('${directory.path}/folio_settings.v1.json.tmp').exists(),
      isFalse,
    );
  });

  test('corrupt settings file does not prevent controller startup', () async {
    final directory = await Directory.systemTemp.createTemp('folio-corrupt-');
    addTearDown(() => directory.delete(recursive: true));
    await File('${directory.path}/folio_settings.v1.json').writeAsString('{');
    final controller = FolioSettingsController(
      store: FileFolioSettingsStore(directoryProvider: () async => directory),
    );
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.settings, const FolioSettings());
  });

  test(
    'atomic writer replaces content and leaves no staging or backup files',
    () async {
      final directory = await Directory.systemTemp.createTemp('folio-atomic-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/cache.json');
      await writeFileAtomically(file, 'old');
      await writeFileAtomically(file, 'new');
      expect(await file.readAsString(), 'new');
      final leftovers = await directory
          .list()
          .where((entry) => entry.path.endsWith('.tmp') || entry.path.endsWith('.bak'))
          .toList();
      expect(leftovers, isEmpty);
    },
  );

  test('staging paths are unique per call', () {
    final first = temporaryPathFor('/data/cache.json');
    final second = temporaryPathFor('/data/cache.json');
    expect(first, isNot(second));
    expect(first, startsWith('/data/cache.json.'));
    expect(first, endsWith('.tmp'));
  });

  test('failed staging write preserves the previous destination', () async {
    final directory = await Directory.systemTemp.createTemp(
      'folio-atomic-fail-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/cache.json');
    await file.writeAsString('last-good');
    // A directory at the staging path forces a write error even when tests
    // run as an administrator (chmod-based permission tests are unreliable).
    final blockedStaging = Directory('${directory.path}/blocked.tmp').path;
    await Directory(blockedStaging).create();
    await expectLater(
      writeFileAtomically(file, 'replacement', temporaryPath: blockedStaging),
      throwsA(isA<FileSystemException>()),
    );
    expect(await file.readAsString(), 'last-good');
  });

  test('failed backup swap preserves the previous destination', () async {
    final directory = await Directory.systemTemp.createTemp(
      'folio-atomic-backup-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/cache.json');
    await file.writeAsString('last-good');
    // A directory at the backup path makes the "move the last good file
    // aside" step fail before the destination is ever touched: the write
    // must fail without destroying the previous file (the old delete-then-
    // rename implementation lost it exactly here).
    await Directory('${file.path}.bak').create();
    await expectLater(
      writeFileAtomically(file, 'replacement'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await file.readAsString(), 'last-good');
  });
}

class _ControlledStore implements FolioSettingsStore {
  final loaded = Completer<FolioSettings>();
  final firstWriteStarted = Completer<void>();
  final firstWriteFinished = Completer<void>();
  final written = <FolioSettings>[];
  bool blockFirstSave = false;
  bool failWrites = false;
  int activeWrites = 0;
  int maxConcurrentWrites = 0;

  @override
  Future<FolioSettings> load() => loaded.future;

  @override
  Future<void> save(FolioSettings settings) async {
    activeWrites++;
    if (activeWrites > maxConcurrentWrites) {
      maxConcurrentWrites = activeWrites;
    }
    try {
      if (!firstWriteStarted.isCompleted) {
        firstWriteStarted.complete();
        if (blockFirstSave) {
          await firstWriteFinished.future;
        }
      }
      if (failWrites) {
        throw const FileSystemException('Simulated full disk');
      }
      written.add(settings);
    } finally {
      activeWrites--;
    }
  }
}
