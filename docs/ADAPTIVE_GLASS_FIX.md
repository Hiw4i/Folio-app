# Adaptive glass: correctness and GPU cost

Validated on 2026-10-30 with Flutter's Android Impeller renderer.

## Office follow-up (build 2)

The first validation below covered Flutter-painted backgrounds. It did **not**
establish correctness over the real DOCX/PPTX platform view. The user's follow-up
identified that missing boundary, and real Office integration tests reproduced
the unreadable/missing foreground in both formats.

Office had forced `initExpensiveAndroidView`: Hybrid Composition renders the
WebView separately and creates cropped Flutter overlay surfaces. This breaks
the foreground shader's root-coordinate assumption and prevents normal glass
composition over the document. Office now uses texture composition through
`initSurfaceAndroidView`; tests assert that HC fallback did not activate.
The Activity's root rendering mode and the other document formats are unchanged.

An additional real-GPU vertical-split test reproduced a second issue: manually
flipping the runtime-effect backdrop UV on the tested Impeller OpenGLES path
sampled the opposite end of the page. The extra flip is removed. A diagnostic
shader confirmed the actual input size, and an ADB screenshot of the Android
window confirmed white ink over the dark document half, black ink over its
light half, and real background blur. This is not solely a `toImage` assertion.

The old Android window magnifier cannot read an offscreen WebView texture.
Owned handle events now drive a Flutter Material magnifier sampling that same
document texture. Normalized viewport coordinates receive no extra DPR/zoom
factor. A notifier rebuilds only the loupe; focus loss, app backgrounding,
inactive selection, errors and detach dismiss it. Native selection, DOM handles,
haptics and Copy/Select all remain in their existing owners.

`integration_test/office_glass_test.dart` uses generated, offline OOXML files,
not a Flutter-painted document substitute. It checks both formats, repeated
menu opening/closing, complete glyph coverage, opposite neighboring tones,
actual blur variance, real DOM Select all/Copy, magnifier pixel contents and
inactive-app suppression. Handle-message injection validates the Flutter
boundary, not a physical Chromium longpress-and-drag sequence.

```powershell
flutter test integration_test/all_glass_test.dart -d <android-device> --enable-impeller --dart-define=FOLIO_REQUIRE_GPU=true --reporter expanded
```

Complete replacement of the Office layout engine by Flutter is outside this
fix: reliable DOCX layout requires pagination, font metrics, tables, wrapping,
headers and floating objects. Texture composition lets the existing layout
engine participate in Flutter's rendering without that independent rewrite.

Build 2 verification: 470 Flutter tests passed (11 GPU-only skips in the
software runner), all 14 combined Android/Impeller checks passed, all 15
standalone shader checks passed, and `flutter analyze` reported no issues.
The real-DOM Copy/Select all assertions passed for both DOCX and PPTX.

## Causes and changes

- Global glyph-mask and backdrop-sample coordinates previously updated only
  during render-object paint. Flutter can move a retained repaint boundary
  without repainting its children. A GPU regression reproduced missing ink
  after a 32-point ancestor translation. The foreground layer now refreshes
  coordinates, clip and source coverage during scene composition, without
  invalidating or rerasterizing the widget subtree.
- Expanding menus shared the reader's pre-surface backdrop with earlier
  controls. Overlap therefore blurred the wrong input. Morphing surfaces now
  have independent backdrop inputs. Resting disjoint shells still share their
  common blur; shells with a different animated sigma leave that batch.
- Motion blur previously composed a native Gaussian outside every glyph's
  shader, creating large intermediate textures and extra passes. A fixed
  normalized 5x5 kernel now softens only cached glyph alpha inside the shader.
  Transparent mask edges and halo coverage are explicit. Backdrop luminance
  sampling remains independent of glyph blur and opacity.
- Unsupported shader renderers receive outlined white text when transparent
  glass is enabled. Opaque controls retain their existing plain-white text.

Each physical control keeps its own sample group. Text and icons within that
control agree; neighboring controls can select opposite foreground colors.
The production path performs no pixel readback or scheduled CPU color updates.
Mask images, shaders, coverage pictures and engine layers are reused/disposed
by their owners; fully hidden glyphs submit no backdrop pass.

## Initial verification (Flutter-painted backgrounds)

- `flutter analyze`: no issues.
- `flutter test`: 467 passed, 10 GPU-only tests skipped by the software runner;
  existing visual goldens passed without changing their reference images.
- Android/Impeller integration suite: 11 passed, including strict renderer
  enforcement, overlap, retained transforms, device density 3x, full glyph
  coverage, motion softening, opposite neighboring tones and resource reuse.
- Standalone GLSL harness: 15 passed on ANGLE/D3D11, exercising both target-define
  configurations, alpha/premultiplication, transforms and halo.

```powershell
flutter test
flutter analyze
flutter test integration_test/adaptive_glass_test.dart -d <android-device> --enable-impeller --dart-define=FOLIO_REQUIRE_GPU=true --reporter expanded

# Windows: point to the Android SDK's bundled ANGLE libraries if needed.
$env:FOLIO_EGL_DIRECTORY = '<android-sdk>/emulator/lib64/gles_angle'
python tools/adaptive_glass/check_shader.py
```

## Measured workload

Same isolated Android 16 emulator, 1080x2400 output, two adaptive glyph masks,
changing opacity, translation and motion sigma, 24 GPU render/readback samples:

| Render + readback | Native Gaussian composition | Mask-only shader blur |
| --- | ---: | ---: |
| Median | 165.690 ms | 80.708 ms |
| p90 | 207.414 ms | 120.938 ms |

The median is approximately 2.05x faster. These earlier measurements concern
Flutter-painted backgrounds, not native Office performance. This synthetic debug/emulator
workload includes full image readback and is **not an animation FPS measure**.
Physical-device profile-mode timing remains necessary for device-specific FPS
or thermal/power claims. Per-glyph backdrop work remains; the change removes
native Gaussian intermediates rather than promising zero GPU cost.
