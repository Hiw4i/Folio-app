# Folio Total Refactoring — Implementation Plan

> **Execution status (2026-10-29):** Tracks 1–4 delivered in commits
> `b1d9819`…(HEAD): AppLog + global handlers; data-loss-safe atomic writes
> (+ delete-pending retry, path-type check); settings quarantine + scope
> warning; AppCurves/AppMotion tokens; CoalescingDrainer (both layers);
> BoundedTextMeasurer; TitleTruncator; ChromeScrollIntentAccumulator;
> reader_screen decomposition; edge-scroller shim removal; honest library
> failures + resume cooldown. 466 tests green, analyze clean.
> **Deferred deliberately (highest-risk semantic merges, need their own
> session):** Task 2.5 glass-controller dedup (drifted settle semantics must
> be reconciled carefully), Task 3.5 renderer seek-coalescer extraction,
> Task 3.7 scrubber contract interface, markdown RegExp hoisting.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement
> this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the 94-file codebase (~20.5k LOC lib / ~13k LOC tests) to a strict
standard: honest error handling, no silent data loss, zero duplicated logic clusters,
all motion/visual values tokenized, decomposed widgets, and validation at trust
boundaries — with **zero behavior change** except the six explicitly listed fixes.

**Architecture:** Behavior-preserving refactor in 5 tracks (Reliability → Tokens/DRY →
Reader → Library → Verification). Every task ends green on `flutter analyze` + the
full test suite. New abstractions are extracted from ≥2 existing real use sites only
(no speculative DRY), keeping the user's constraint: deduplicate clusters, do not
force-merge everything.

**Tech Stack:** Flutter 3.x / Dart ^3.13.2, flutter_test, flutter_lints 6.

**Spec:** User request "тотальный рефакторинг по 7 стандартам" + audit reports
(glass subsystem, library/shared, reader) captured below.

## Global Constraints

- **Baseline must be green before any edit:** `flutter analyze` → 0 issues; `flutter test` → all pass.
- **Uncommitted WIP is untouchable intent:** the working tree carries deliberate changes
  to `liquid_morphing_control.dart` (retained expanded child) and `folio_settings.dart`
  (`blurEnabled` default off). Refactors build on top; never revert or "clean up" these.
- **Behavior-freeze list — changes allowed ONLY where a task names them explicitly:**
  1. `atomic_file.dart` Windows data-loss fix (Track 1) — deliberate correctness fix.
  2. Silent `catch (_)` blocks get stack-trace logging (no user-visible change).
  3. Glass segmented-control a11y label `'$label documents'` → injectable label.
  4. Settings store quarantines file on *any* read error (was: FormatException only).
  5. Settings scope asserts in debug when the scope is missing (silent default in release stays).
  6. Library full re-scan on every `AppLifecycleState.resumed` gets a cooldown.
- **No new dependencies.** No renames of files unless the plan lists the rename.
- **Every extracted abstraction has ≥2 real call sites** in this codebase (anti-YAGNI rule).
- **Command contract:** verify with `flutter analyze` (expect "No issues found") and
  `flutter test` (expect "All tests passed!"); commit after each task.

## Review Focus

The five failure modes most likely to bite a real user, each pinned by a test:

1. **Process death between `destination.delete()` and `rename` on Windows** — settings
   and library cache must survive; pinned by `test/shared/settings/folio_settings_test.dart`
   (backup-rename restore test added in Task 1.1).
2. **Concurrent writers to one destination share one `.tmp`** — a second writer must not
   corrupt the first; pinned by unique tmp-path helper + test in Task 1.1.
3. **Rapid open/close of a document** races renderer lifecycle — pinned by existing
   `reader_async_regression_test.dart`; must stay green through Track 3.
4. **Coalesced writer must never run two writes concurrently** — pinned by existing
   `maxConcurrentWrites == 1` tests; must stay green through Track 2's `CoalescingDrainer`.
5. **Glass motion must settle when liquid motion is toggled off mid-gesture** — pinned by
   existing `liquid_drag_parity_test.dart` / `liquid_glass_control_test.dart`; stays green
   through the controller dedup (Task 2.5).

---

## Track 1 — Reliability: persistence + error policy

### Task 1.1: `atomic_file.dart` — eliminate the data-loss window

**Files:**
- Modify: `lib/shared/persistence/atomic_file.dart`
- Test: `test/shared/settings/folio_settings_test.dart` (atomic-writer tests at the bottom)

**Interfaces:**
- Produces: `String temporaryPathFor(String destinationPath)` — exported so tests can
  inject failures at the real temp path; `writeFileAtomically(File, String)` (signature unchanged).

Current bug: the Windows branch (`atomic_file.dart:16-17`) does `destination.delete()`
then `temporary.rename()`. A crash/disk-full/antivirus lock between the two destroys the
last good file — contradicting the file's own docstring. Also: the fixed `.tmp` name makes
two concurrent writers on one destination race the same temp file.

- [ ] **Step 1: Write the failing tests** — in `folio_settings_test.dart`:
  (a) "atomic writer backs up the previous file and restores it when the swap fails":
  pre-create destination with `last-good`; make the *swap* fail by creating a **directory
  at the destination's `.bak` path** (rename-to-backup then fails while destination is intact);
  expect `throwsA(isA<FileSystemException>())` and destination still reads `last-good`.
  (b) "atomic writer uses a caller-derivable unique temp path": assert
  `temporaryPathFor(file.path)` differs from `'$file.path.tmp'` on two calls and that no
  `*.tmp` file remains after success.
- [ ] **Step 2: Run tests, expect FAIL** — `flutter test test/shared/settings/folio_settings_test.dart`
- [ ] **Step 3: Implement** — new algorithm:
  1. `tmp = destination.temporaryPath` (unique suffix: microsecond stamp; overwrite-safe).
  2. Write tmp with `flush: true`.
  3. If destination exists: `rename` destination → `destination.bak`. On failure → rethrow
     (last-good intact).
  4. `rename` tmp → destination. On failure → best-effort restore `.bak` → destination, rethrow.
  5. Best-effort delete `.bak`; best-effort delete leftover tmp (as today).
- [ ] **Step 4: Run tests, expect PASS** (both new + all existing settings tests).
- [ ] **Step 5: Commit** — `fix: never destroy the last good file during atomic writes`.

### Task 1.2: `AppLog` diagnostics facade + global error handlers

**Files:**
- Create: `lib/shared/diagnostics/app_log.dart`
- Modify: `lib/main.dart`, `lib/features/library/data/file_library_repository.dart:170`,
  `lib/features/library/logic/library_controller.dart` (8 catch sites), `lib/features/library/data/document_scanner.dart:220`
- Test: `test/shared/diagnostics/app_log_test.dart` (new)

**Interfaces:**
- Produces: `AppLog` with static `void d(String message)`, `void w(String message, [Object? error, StackTrace? stack])`,
  `void e(String message, Object error, StackTrace? stack)`. `d` no-ops in release
  (`kReleaseMode`); `w`/`e` always print with `debugPrint` including error + abbreviated stack.
  No cross-cutting dependencies (pure foundation import).

All existing `debugPrint('...: $error')` sites log without stack traces; `catch (_)`
sites log nothing. This task makes silence impossible to reintroduce unnoticed.

- [ ] **Step 1: Write failing test** — `AppLog.e` produces output containing message and
  error text; `AppLog.d` is silent under `kReleaseMode` simulation (inject a `verbose`
  flag; default `kDebugMode`).
- [ ] **Step 2: Implement `AppLog`** (trivial, ~40 lines).
- [ ] **Step 3: Wire global handlers in `main()`**: `FlutterError.onError = (details) { FlutterError.presentError(details); AppLog.e('Uncaught framework error', details.exception, details.stack ?? StackTrace.empty); }` and `PlatformDispatcher.instance.onError = (error, stack) { AppLog.e('Uncaught platform error', error, stack); return false; }` — presentError first so dev tooling is unchanged.
- [ ] **Step 4: Replace swallowed catches** — audit-listed sites (`file_library_repository.dart:53,170,312,317`,
  `library_controller.dart` catch blocks, `document_scanner.dart:220` keep stack instead of `'$error'`,
  `reader_screen.dart:244,314` expected-cancellation catches log at `d` level only).
  Semantics preserved (same control flow); only the log line changes.
- [ ] **Step 5: `flutter analyze` + targeted tests PASS.**
- [ ] **Step 6: Commit** — `feat: add AppLog facade and global error handlers`.

### Task 1.3: Settings store quarantine + scope assertion

**Files:**
- Modify: `lib/shared/settings/folio_settings_store.dart:39-48`, `lib/shared/settings/folio_settings_scope.dart:20-21`
- Test: extend `test/shared/settings/folio_settings_test.dart`

- [ ] **Step 1: Failing test** — "a settings file that throws while reading is quarantined":
  store whose `load` throws `FileSystemException` on the real file → subsequent load returns
  defaults, poisoned file moved to `.corrupt` suffix (reuse existing quarantine mechanism).
- [ ] **Step 2: Implement** — broaden the quarantine catch from `FormatException` to all
  read errors, exactly as the file's own comment already promises.
- [ ] **Step 3: Scope assertion** — in `FolioSettingsScope.settingsOf`, add
  `assert(false, 'FolioSettingsScope is missing above this widget...')`-style debug assert
  (silent default fallback remains for release).
- [ ] **Step 4: Tests + analyze PASS, Commit.**

## Track 2 — Tokens, motion DRY, shared abstractions

### Task 2.1: Motion tokens — `AppCurves` + reduced-motion helper

**Files:**
- Create: `lib/shared/theme/app_curves.dart`
- Modify: `lib/shared/theme/folio_theme.dart` (export app_springs — barrel hole — + app_curves)
- Modify (6 reduced-motion copies): `lib/app/folio_root.dart:90-93`,
  `lib/features/library/widgets/library_screen.dart:123-128,508`, `lib/features/library/widgets/document_row.dart:53,57`,
  `lib/shared/widgets/folio_bottom_sheet.dart:79-84,241-243`
- Modify (inline `easeOutCubic` ×5): folio_root.dart:59, document_row.dart:54, folio_bottom_sheet.dart:244,316, folio_selection_toolbar.dart:241
- Test: extend `test/shared/widgets/scale_reveal_test.dart`-style unit test for the helper.

**Interfaces:**
- Produces: `AppCurves` (static tokens: `emphasized = Curves.easeOutCubic`, … — only
  curves actually used) and `Duration AppMotion.resolve(BuildContext, Duration base)` →
  `MediaQuery.disableAnimationsOf(context) ? Duration.zero : base`.

- [ ] **Step 1: Create `AppCurves` + helper, export via `folio_theme.dart`.**
- [ ] **Step 2: Replace all 6+5 sites; each site keeps identical timings.**
- [ ] **Step 3: analyze + full suite PASS, Commit.**

### Task 2.2: `CoalescingDrainer` — one single-writer queue for two layers

**Files:**
- Create: `lib/shared/persistence/coalescing_drainer.dart`
- Modify: `lib/shared/settings/folio_settings_controller.dart:90-117`,
  `lib/features/library/data/file_library_repository.dart:337-367`
- Test: `test/shared/persistence/coalescing_drainer_test.dart` (new)

**Interfaces:**
- Produces: `class CoalescingDrainer { CoalescingDrainer(Future<void> Function() drain); void request(); Future<void> flush(); }`
  — exactly the `_saveRequested`/`_writeRequested` + `whenComplete`-rearm pattern both
  implementations share. Behavior identical to the pinned tests (`maxConcurrentWrites == 1`,
  latest value wins, pending work completes after dispose).

- [ ] **Step 1: Failing test** — request during drain re-arms; flush awaits completion; no overlap.
- [ ] **Step 2: Implement (~35 lines).**
- [ ] **Step 3: Adopt in both call sites; existing serialization tests must stay green unchanged.**
- [ ] **Step 4: analyze + suite PASS, Commit.**

### Task 2.3: Shared bounded text-measure cache

**Files:**
- Create: `lib/shared/utils/text_measurer.dart`
- Modify: `lib/features/reader/widgets/reader_screen.dart:1093-1119` (title cache) and
  `:1322-1348` (search-navigator cache — same pattern duplicated)
- Test: `test/shared/utils/text_measurer_test.dart` (new)

**Interfaces:**
- Produces: `class BoundedTextMeasurer { BoundedTextMeasurer({int capacity = 256}); double widthOf(String text, TextStyle style, TextDirection direction, TextScaler scaler); }`
  — key = `text|direction|styleHash|scale`, cache bounded by wholesale-clear (as today).

- [ ] **Step 1: Failing test** — same key hits cache (painter count via injected hook or
  double-call identity), capacity clears.
- [ ] **Step 2: Implement; adopt at both reader_screen sites (deleting both private caches).**
- [ ] **Step 3: analyze + suite PASS, Commit.**

### Task 2.4: Glass token consolidation (identical duplicates only)

**Files:**
- Modify: `lib/shared/glass/core/glass_tokens.dart` (new named constants),
  `lib/shared/glass/core/liquid_shape.dart:110-115`, `lib/shared/glass/core/glass_geometry.dart:264-269`
  (delete private `_limit`/`_limitOffset`, use `LiquidSpring.limitOffset`),
  `lib/shared/glass/surface/liquid_surface.dart:115`, `lib/shared/glass/widgets/liquid_container.dart:148`
  (single `panelFill`), `liquid_surface.dart:113` + `glass_panel.dart:12` + `liquid_motion_panel.dart:18`
  + `liquid_morphing_control.dart:22` + `liquid_container.dart:85` (single `GlassTokens.cornerRadius`),
  hit-slop `8` ×3 → `GlassTokens.hitSlop`, morph threshold `0.68` ×2 → token,
  clamp `(-0.035, 1.065)` ×2 → token, `exp(-dt*22)` light-follow ×2 → base-class method (Task 2.5).
- Deliberately NOT unified (values differ intentionally): optical padding 40 vs 42 vs 44 —
  kept as distinct named constants with a comment, per the "don't over-DRY" constraint.
- Test: existing glass suite is the net (no visual-value changes permitted).

- [ ] **Step 1: Add tokens; replace duplicates one file at a time.**
- [ ] **Step 2: `flutter test test/shared/glass` after each file; full suite at the end; Commit.**

### Task 2.5: Glass controller dedup + integrity fixes

**Files:**
- Modify: `lib/shared/glass/core/liquid_motion_controller.dart` (base: `setLiquidMotionEnabled`
  template, pointer-velocity helper, `followLight(dt)`, backdrop gate in `isAtRest`),
  `lib/shared/glass/motion/glass_motion_controller.dart` (24-26,68-110,141-155,189-197,398-404),
  `lib/shared/glass/motion/liquid_segmented_controller.dart` (31-57,83-96,141-149,284-288),
  `lib/shared/glass/widgets/liquid_segmented_control.dart:317` (semantic label injection),
  `lib/shared/glass/liquid_glass.dart` (barrel: export `liquid_motion_panel.dart`, `liquid_surface_style.dart`)
- Test: existing glass suite (drag parity, control, panel, surface style tests) is the net.

- [ ] **Step 1: Lift shared members into `LiquidMotionController` base; subclasses keep their
  semantic differences (settle-all vs stop-simulation) as the template hook.**
- [ ] **Step 2: Fix `setReducedMotion` full-token comparison (both controllers).**
- [ ] **Step 3: Segmented control takes `semanticCountNoun` (default 'documents'); no caller change.**
- [ ] **Step 4: Barrel exports + `folio_theme.dart` export of `app_springs`.**
- [ ] **Step 5: analyze + full glass suite PASS, Commit.**

## Track 3 — Reader decomposition (finalize after reader audit lands)

### Task 3.1: Extract pure title-truncation logic

**Files:**
- Create: `lib/features/reader/logic/title_truncation.dart` (moves `_truncateTitle`,
  `_truncateWithSuffix`, `_titleMeasureStyle`; uses `BoundedTextMeasurer`)
- Modify: `lib/features/reader/widgets/reader_screen.dart:1079-1177`
- Test: `test/features/reader/title_truncation_test.dart` (new: keeps extension, narrow
  suffix shrink, maxWidth ≤ 0 → ellipsis, cached repeats)

- [ ] Steps: failing tests → move code → adopt → suite PASS → Commit.

### Task 3.2: Extract chrome visibility state machine

**Files:**
- Create: `lib/features/reader/logic/chrome_visibility.dart` — pure decider:
  `ChromeVisibilityController({threshold, enabled})` with `recordScroll(delta, {canHide, blocked})`
  → `ChromeCommand {none, show, hide}` and `resetIntent()`.
- Modify: `reader_screen.dart` `_recordChromeScroll`/`_setChromeTarget` to delegate.
- Test: `test/features/reader/chrome_visibility_test.dart` (intent accumulation both
  directions, threshold crossing, blocked-state zeroing, disabled preference).

### Task 3.3: Split `reader_screen.dart` (1656 lines) into focused widgets

**Files:**
- Create: `lib/features/reader/widgets/reader_search_navigator.dart` (`_SearchNavigator`,
  `_SearchStepButton`), `lib/features/reader/widgets/reader_menu_overlays.dart`
  (`_ReaderExitMenu` — also dedupe the primary/secondary swap, `_ReaderMenuContent`, `_MenuAction`),
  `lib/features/reader/widgets/reader_status_views.dart` (`_ReaderStatus`, `_ReaderFailureView`,
  `_ReaderBackground`), `lib/features/reader/widgets/office_staged_view.dart` (`_OfficeStagedView`).
- Modify: `reader_screen.dart` shrinks to the screen + `_TopChromeContent` family.
- Test: existing `reader_screen_test.dart` + `reader_async_regression_test.dart` are the net.

### Task 3.4: Edge-scroller shim removal (audit finding: no real duplication)

Audit verdict: PDF composes the shared `SelectionEdgeScrollDriver`; the third file
`text/logic/selection_edge_scroller.dart` is a 1-line re-export shim that misleads
navigation. Point its two importers (`text/widgets/text_document_selection.dart:22`, the
shim's test) at `../../logic/selection_edge_scroller.dart` and delete the shim.

### Task 3.5: Renderer dedup — seek coalescer, progress, failure mapping

**Files:**
- Create: `lib/features/reader/logic/seek_coalescing.dart` — mixin holding
  `_seekRevision/_seekRunning/_pendingSeekFraction` + the coalesced `while` drain,
  driven by an injected performer (pdf_document_renderer.dart:75-115 ↔
  office_document_renderer_base.dart:297-349, ~40 identical lines each).
- Create: `lib/features/reader/logic/reader_failure_mapping.dart` — single kind→ReaderFailure
  mapping (pdf:545-556 ↔ office:374-385 ↔ text:89-99).
- Modify: both renderers + `text_document_renderer.dart`; dedupe `hasNoSearchableText`
  and the open()-reset block where the base class allows.
- Test: existing `word_document_renderer_test.dart`, `reader_scrubber_test.dart`,
  `text_document_renderer_test.dart` are the net; add seek-coalescer unit test
  (three rapid seeks → one trailing perform, generation guard).

### Task 3.6: Reader search & render hot-path fixes

- `text/logic/text_document_renderer.dart:257-259,151` — cache per-document lowercase
  projection + chunk-start offsets (invalidated by document identity, not per query).
- `text/logic/markdown_selection_text.dart:182,241,436,588` — hoist 4 per-iteration RegExps
  to static finals.
- `pdf/logic/pdf_document_renderer.dart:388-401` — bound `_resolveTextAvailability`
  probe to the first `_maxTextProbePages` (constant, 12) pages; log when truncated.
- `pdf/widgets/pdf_document_view.dart:302-329` — gate the global pointer router on
  active selection before touching delegate or allocating `_selectionKey`.
- `pdf/logic/pdf_selection_edge_scroller.dart:169-173` + `pdf_document_view.dart:390-392`
  — replace FIFO-evicting "LRU" maps with the real bounded map from Task 2.3's pattern
  (or genuine access-order eviction).
- `pdf/logic/pdf_document_renderer.dart:239,135,148,176,511`, `office_document_renderer_base.dart:142`,
  `text_document_renderer.dart:108`, `office_document_platform_view.dart:71` — AppLog every
  swallowed catch (open-failure causes become diagnosable).
- Delete dead `UnsupportedDocumentRenderer` (+ its test) — the exhaustive factory switch
  makes it unreachable; and drop the dead revision check in `_doSeek` (pdf:96-104).

### Task 3.7: Scrubber contract naming

`reader_scrubber.dart:86-89,215-225` is-casts exist because progress API lives outside the
`DocumentRenderer` contract. Add a small `ReadingProgress` interface (fraction/label/
positionCount/currentPosition) implemented by pdf/office/text renderers; scrubber drops the
casts. Same-file fix: `_ReaderScrubberSizes.pillHeight` dup of `_pillHeight` (:561 vs :46).

## Track 4 — Library & data layer

### Task 4.1: Scanner isolate — typed messages, not JSON ping-pong

**Files:**
- Modify: `lib/features/library/data/document_scanner.dart:82-122,167-169`
- Test: existing `library_async_regression_test.dart` + `file_library_repository_test.dart`.

Send `DocumentEntry` instances directly over `SendPort` (plain immutable Dart objects are
sendable); kills per-batch `fromJson` + `cast<String, Object?>` on the UI isolate for
thousands of entries. Fix double `_isExcludedAndroidDirectory` call (:171,:179).

### Task 4.2: Repository dedup + honest cache errors

**Files:**
- Modify: `lib/features/library/data/file_library_repository.dart` — merge
  `consumeInitialDocument`/`_registerIncoming` merge-blocks (:158-164 vs :240-248);
  single source for the "remove vs reset lastOpenedAt" rule shared with
  `library_controller.dart:397`; AppLog on cache-read failures (:312,317);
  remove dead `lastCacheWriteError` field if grep confirms zero readers;
  `FileDocumentSource` path validation (:260-262 — reject empty/relative paths).
- Test: `file_library_repository_test.dart` + new validation test.

### Task 4.3: Library controller — uniform failures, dead code removal

**Files:**
- Modify: `lib/features/library/logic/library_controller.dart` — AppLog+stack in all 8
  catches; `recoverUnavailable` (:367) sets a failure flag the UI can show; stop mapping
  `requestFullAccess` errors onto `_refreshFailed` (:271-275 — lies in UI copy at
  library_screen.dart:325-328); remove dead `open()` (:296-304, grep-confirmed);
  move `LibraryFilterPresentation` to `lib/features/library/widgets/library_filter_labels.dart`.
- Test: `library_controller_test.dart` stays green; new test for recoverUnavailable flag.

### Task 4.4: Library screen — resume cooldown + UI-token cleanup

**Files:**
- Modify: `lib/features/library/widgets/library_screen.dart` — resume re-scan cooldown
  (named constant, e.g. 10 s; per Global Constraint #6); `MediaQuery.of` → narrow
  `…Of(context)` accessors (:196); reuse `FolioSheetDivider` instead of hand-rolled
  divider (:455-465); fold `_RefreshFailureNotice` (:736-768) into `FolioStatusView`;
  hardcoded `Color(0x1FFFFFFF)`/`Color(0x0DFFFFFF)` → `appColors` tokens.
- Modify: `lib/features/library/widgets/document_row.dart:8` — remove utility re-export
  (callers import `shared/utils/file_format.dart` directly); Inter TextStyle → `AppTextStyles`.
- Modify: `lib/shared/widgets/folio_sheet_content.dart` — hoist `ThemeData.dark().copyWith`
  to a static final (built once, :26-31).

### Task 4.5: Library screen open-flow orchestration

**Files:**
- Modify: `lib/features/library/widgets/library_screen.dart:521-547` — the
  `Future.delayed(AppDurations.medium, markOpened)` timer tied to the OpenContainer
  morph duration becomes an explicit on-closed hook where the container API allows;
  document the coupling in the single place that owns it.
- Test: `library_async_regression_test.dart` green.

## Track 5 — Verification & self-review

- [ ] `flutter analyze` → "No issues found".
- [ ] `flutter test` → all pass (compare count with baseline).
- [ ] Internal hard review of the full diff: find 3 weak spots in the plan-as-executed,
  fix or explicitly justify each in the final report.
- [ ] Update plan checkboxes; commit any stragglers.
