# Reader selection unification implementation plan

**Goal:** Consistent text-only selection, viewport-edge scrolling, rounded highlights and animated Copy/Select all across the document readers, plus an original launcher icon.

**Specification:** The user's 2026-10-29 request in this session. Existing Flutter 3.47 / Dart 3.13, pdfrx 2.6.1 and offline Office renderers remain the platform.

**Architecture:** Keep format-specific text extraction and hit testing behind adapters. Share Dart edge-motion policy between text and PDF, mirror its physical units in Office. A reusable spring reveal animates a persistent toolbar presentation; framework menu removal releases presentation ownership instead of cutting off the exit animation. Retain lazy loading and bounded caches.

**Constraints:** No new runtime dependencies, no unrelated repository rewrite, preserve the existing dirty pubspec.lock, no private Chromium popup inspection, no content extraction on every scrolling frame. Changes remain uncommitted for review.

## Work

- [x] Office: reproduce image selection and missing held-pointer scrolling; add browser regressions; implement text-only selection and owned, cancellable edge scrolling; use PDF's 4px highlight radius; cache document-space highlights during ordinary scrolling.
- [x] PDF/text: extract a renderer-independent frame-driven edge policy; adapt PDF handle hit testing and range replay after scrolling; bound asynchronous text extraction and stop on cancellation/lifecycle/document changes; add regressions.
- [x] Motion: test reduced motion, overshoot, reversal, hidden input/focus/semantics and teardown. Implement a shared 220ms / 0.22-bounce ScaleReveal and toolbar presentation host that retains exiting content and coalesces menu recreation.
- [x] Icon: author a vector Folio mark, adaptive/monochrome resources and reproducible legacy density assets; inspect the rendered result.
- [x] Integration: run focused regressions, full Flutter suite, Office browser suite, static analysis, source integrity, Android build and independent code review. Record any environmental or physical-device verification limits.

## Review focus

Stationary held pointers, reversed selection and multiple pointers; native Office handle ownership; menu replacement while exiting; route/focus/disposal cleanup; large selections without repeated DOM/page extraction; reduced-motion changes mid-animation; zoom and orientation coordinates.

## Ownership

Office and PDF adapters are independent delegated tasks. Launcher assets are a third independent task. Shared toolbar presentation, animation and integration stay in the main session.


## Verified outcome — 2026-10-29

- `flutter test --no-pub --reporter expanded`: 436 passed, 5 skipped.
- `flutter analyze --no-pub`: no issues.
- `python -m unittest discover -s tools/office_renderer_tests -q`: 99 passed in 73.580s, using installed Edge (offline bundled assets).
- `flutter build apk --debug --no-pub`: succeeded. Packaged Office assets were compared byte-for-byte with the tested sources.
- `python tools/check_source_integrity.py` and `git diff --check`: passed.
- Independent reviews covered toolbar lifecycle/focus, PDF transform/selection updates and Office gestures/native API usage. Reproduced and fixed tap-region focus loss, unsupported-menu retention, handle crossing and second-pointer takeover.
- Office browser tests contained seven obsolete frame-navigation expectations; all were reproduced against an untouched HEAD asset copy before updating the tests to the existing one-active-frame contract.
- Launcher resources passed Android resource compilation and deterministic regeneration; adaptive/monochrome previews were visually inspected.

## Performance and lifecycle boundaries

The Dart readers share a frame-driven edge policy (72 logical px zone, 280–1000 px/s, 900ms dwell, 1500ms ramp, at most 60% additional speed and a 50ms frame cap). Office mirrors that policy in one named configuration and preserves fractional travel across frames. Browser tests confirm equal travel at 60/120Hz. Office scrolling refreshes visible highlights at most every 64 ms; drags and quiet frames repaint immediately. PDF text loads are coalesced and generation-guarded; page text, character geometry and highlight paths have separate bounded caches.

The common toolbar host owns presentation lifetime, preserving the exit after a framework menu is removed. Scale and opacity share an unbounded spring; hidden actions immediately leave hit testing, focus and semantics. Existing reader format adapters retain their extraction and hit-testing responsibilities.

No physical-device frame-time, Android WebView zero-size native-handle suppression, or magnifier-composition check was performed. Browser tests validate DOM gestures and rendering; PDF coordinator tests validate transforms, ranges, zoom, resizing and asynchronous cancellation through a controlled viewer boundary. These do not establish physical-device smoothness.
