import 'package:folio/features/tutorial/data/tutorial_progress_store.dart';
import 'package:folio/features/tutorial/tutorial_catalog.dart';

/// In-memory store that behaves like a real one: [load] returns the last
/// saved state, so a revived controller sees persisted progress.
class MemoryTutorialStore implements TutorialProgressStore {
  MemoryTutorialStore([Set<TutorialTour>? seed])
    : _state = seed ?? <TutorialTour>{};

  /// Every tour already seen: tests that pump the real app inject this so
  /// the looping gesture cues never enter their pump loops.
  MemoryTutorialStore.allSeen()
    : _state = Set<TutorialTour>.of(TutorialTour.values);

  Set<TutorialTour> _state;

  Set<TutorialTour> get saved => _state;

  @override
  Future<Set<TutorialTour>> load() async => _state;

  @override
  Future<void> save(Set<TutorialTour> seen) async {
    _state = Set<TutorialTour>.of(seen);
  }
}
