import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../../shared/diagnostics/app_log.dart';
import '../../../shared/persistence/atomic_file.dart';
import '../tutorial_catalog.dart';

abstract interface class TutorialProgressStore {
  Future<Set<TutorialTour>> load();
  Future<void> save(Set<TutorialTour> seen);
}

/// One JSON file with the gestures the user has already performed.
/// Tutorial progress is feature state, not appearance — kept out of the
/// settings file so the two schemas version independently.
class FileTutorialProgressStore implements TutorialProgressStore {
  FileTutorialProgressStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;

  Future<File> _file() async {
    final directory = await _directoryProvider();
    return File(
      '${directory.path}${Platform.pathSeparator}folio_tutorial.v1.json',
    );
  }

  @override
  Future<Set<TutorialTour>> load() async {
    try {
      final file = await _file();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
        throw const FormatException('Unsupported tutorial progress file.');
      }
      final names = decoded['seen'];
      if (names is! List<Object?>) {
        return <TutorialTour>{};
      }
      return {
        for (final name in names)
          if (TutorialTour.values.where((t) => t.name == name).firstOrNull
              case final TutorialTour tour)
            tour,
      };
    } on FileSystemException {
      // First launch or missing file: nothing seen yet.
      return <TutorialTour>{};
    } catch (error, stack) {
      // A corrupt progress file must never block the UI: start clean and
      // overwrite on the next save.
      AppLog.w('Tutorial progress quarantined', error, stack);
      return <TutorialTour>{};
    }
  }

  @override
  Future<void> save(Set<TutorialTour> seen) async {
    await writeFileAtomically(
      await _file(),
      jsonEncode(<String, Object?>{
        'version': 1,
        'seen': <String>[for (final tour in seen) tour.name],
      }),
    );
  }
}
