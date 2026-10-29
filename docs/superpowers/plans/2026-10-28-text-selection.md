# Stable reader selection implementation plan

**Goal:** Resolve the five reported selection defects while preserving the rounded, joined highlight design.

**Architecture:** Keep Flutter 3.47.7's selection engine and native handles. Add a bounded, frame-driven edge scroll policy, source-aware Markdown copying, and persistent toolbar placement. Selection commands own logical state; scrolling only updates geometry.

**Constraints:** No visual redesign, no unneeded dependencies, preserve lazy document rendering, preserve selection on ordinary scrolling, cancel active work on focus loss/document replacement/disposal.

- [x] Reproduce first-drag missing haptics and edge holding; cover stable wrapped-heading geometry in paint frames and across the viewport edge.
- [x] Add selection edge scrolling at 56 logical pixels from the viewport edge: 80–160 logical px/s initially, 900 ms dwell, smooth acceleration capped at 1.6x, immediate stop on release/cancellation or leaving the edge.
- [x] Use character granularity and content-offset changes for first-drag haptics; retain native handle feedback without duplicate pulses.
- [x] Read public paragraph-owned selectable ranges and calculate their strut boxes directly; retain offscreen neighboring lines so clipping cannot alter the silhouette.
- [x] Copy original Markdown source for select-all; map range endpoints to source positions within known lazy chunks. Cover repeated content, Unicode, reverse selection, partial styles, hidden image URLs and unmounted anchors.
- [x] Stabilize toolbar horizontal position and above/below preference per selection; retain long-press dragged placement through overlay recreation, respecting safe areas and resizing.
- [x] Run focused regressions, static analysis, full Flutter suite and an Android debug build; review integrated diff.

**Review focus:** pointer cancellation and multiple fingers; offscreen selection endpoints; reversed drags and repeated paragraphs; clipboard failure/document replacement; toolbar recreation and orientation changes.

**Execution:** Scoped independent Markdown and toolbar work is delegated; gesture, geometry, integration and verification stay in the main session. The user's explicit task is the specification; changes remain uncommitted for review.

**Verification (2026-10-28):** `flutter analyze` reported no issues. `flutter test --reporter expanded` passed 390 tests with 5 skips. `flutter build apk --debug` succeeded. `git diff --check` reported no whitespace errors. Independent review findings about reverse endpoints, partial-style expansion and empty-image destinations were reproduced and corrected. Touch input and haptic method calls were synthesized in widget tests; physical-device feel was not assessed.

**Follow-up revision:** Immediate pan replaces long press on the toolbar. Position changes animate through actual layout in 140 ms, with stable document-relative anchors and top/bottom edge clamping. Edge scroll speeds are doubled to 160–320 logical px/s before the existing dwell ramp. Reader-owned handle gestures retain native visuals, touch padding and magnification while suppressing Flutter's frame-based haptics; edge scrolling pulses on content-line changes. Full suite: 400 passed, 5 skipped; analysis clean. Physical-device feel remains untested.

**Independent review:** Two agents audited gesture/toolbar lifecycle and Markdown source mapping. Reproduced and fixed seven defects: stale reader state after handle collapse; rejected cross-handle input; same-handle pointer takeover; menu reopening after inactive cancellation; automatic animation stalled by continuous retargeting; inline-code delimiter-run mismatch; formatted image-alt mapping failure. Kept design, gesture thresholds, scroll speeds and dependencies. Final verification: 408 tests passed, 5 skipped; flutter analyze clean; Android debug APK built. Physical-device interaction/performance remains untested.
