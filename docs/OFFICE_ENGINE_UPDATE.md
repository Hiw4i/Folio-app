# Office renderer corrections

## Scope and integration

The update is based on the uploaded `folio.zip`. Dart reader controls, the library,
settings BottomSheet and glass effects are untouched. The existing engines remain
pinned: docx-preview 0.4.0 + JSZip 3.10.1 and PPTXjs 1.21.1 + its existing dependencies.
No CDN, new production dependency, external conversion service or font bundle was
introduced. Vendor license files and copyright notices are preserved.

The readable compatibility code lives in `docx-layout.js` and `pptx-fidelity.js`.
The HTML entry points load each adapter before its corresponding vendor engine.
Vendor files contain small call-site hooks plus necessary changes to the PPTXjs
conversion driver. They are modified vendored sources, not pristine upstream files.
See `android/app/src/main/assets/office/THIRD_PARTY.md` for upstream and patched hashes.
An upstream upgrade must port the hooks and rerun the tests; do not replace only the
minified file or mix it with an adapter from another revision.

## PowerPoint changes

- Relationship targets resolve relative to their owning package part; internal
  traversal beyond the package root and external schemes are rejected. Actual slide
  order follows `p:sldIdLst`. Relationship part names are derived generically rather
  than by replacing `slide1`-like substrings. Missing required slide references fail
  the render instead of announcing a partial deck as ready; optional app.xml is optional.
- Group transforms apply off/ext/chOff/chExt, nested child-space scale and translation,
  rotation and flips. The shipped red diagnostic border is removed. Shape transforms
  can fall back to layout/master transforms when local geometry is absent.
- Picture source cropping occurs before fitting into the authored frame. Reflections,
  rotation, alpha and simple ellipse clipping are preserved. The SVG alternate image
  relationship is used when available; unsupported image formats remain unsupported.
- Text runs merge defaults, master/layout/list/paragraph properties and direct formatting.
  Font sizes use CSS points-to-pixels conversion, not the previous 1.25 multiplier.
  Kerning thresholds are no longer subtracted from font size. Theme font tokens resolve
  to actual family names; a direct bold/italic reset is respected. Paragraph insets are
  applied to the text box and its available line width. Ordinary spaces remain breakable.
- Effective background selection follows slide, layout, master and theme references.
  Color-map overrides include accent slots and master-mapping reset. Master/layout
  decorations are separate layers behind slide content; editing-placeholder samples are
  not painted as slide contents. Background-image alpha affects only the background paint
  layer. CSS background gradients retain stops; SVG gradients additionally preserve
  intermediate positions and use the authored direction rather than reversing the axis.
- Each SVG owns uniquely scoped paint-server IDs, including repeated master shapes.
  A DOM sanitizing pass removes executable elements/event-handler attributes before
  insertion; this is defense in depth, not a security audit or a replacement for native
  local-only loading and CSP.

## Word changes

- The host awaits rendered image decoding and font readiness (bounded by an eight-second
  optional-resource wait) before page measurements. Embedded resources use Blob URLs;
  the document CSP permits blob fonts. Cached page breaks are respected. Active altChunk
  HTML frames are disabled in this restricted document viewer.
- Original column/continuous-section article structure and note-bearing pages are kept.
  Single-article, single-column pages without trailing notes use batched block measurements
  and fragment insertion. There is no repeated append-measure cycle for every paragraph.
  Oversized tables split at row-group boundaries; rowSpan crossings are kept intact.
  Unbreakable blocks retain their content by expanding the preview page.
- Page fitting uses CSS zoom after pagination, keeping document coordinate units intact.
  Reads are batched before zoom writes. Resizing adjusts fit without reprocessing OOXML.
- Image cropping uses an overflow frame rather than centre-origin scaling of a clipped
  source image. Horizontal/vertical flips and image rotation are retained.
- Non-wrapping anchored images are positioned in their page/margin/column/paragraph space
  with a separate behind-text or foreground layer. WrapSquare/Tight/Through are not newly
  implemented. Character/line anchors use the containing paragraph as an approximation.
- Styles are dependency-ordered before the pinned renderer resolves inherited formatting.
  This handles a base style appearing after its derived style in the XML.

## Performance and lifecycle

- Scroll handling uses a cached list of page centres and a binary search, not a complete
  DOM query and getBoundingClientRect sweep per scroll frame. Geometry is refreshed after
  layout and viewport changes. PPTX centring uses the viewport's reserved content height.
- Up to 16 reusable XML parts below 512 KiB of source text each are kept in an LRU cache.
  One-off slide XML trees are not retained by this cache. These are source-text thresholds,
  not claims about the exact size of JavaScript objects in the heap. Cached trees are
  copied before use because PPTXjs mutates inherited structures.
- Repeated embedded pictures reuse a Blob URL for the same package part. DOCX images and
  embedded fonts also avoid base64 URLs. Owned URLs are revoked on pagehide. Memory used
  by the ZIP implementation, decoded bitmaps, DOM and charts is not bounded by the XML
  cache limits and still needs device profiling on large documents.
- The PPTX driver returns an actual conversion Promise and yields between slides. The host
  no longer polls a stable slide count as a proxy for completion. ZIP decompression and
  each individual slide still execute on the WebView thread; this is not worker rendering.
- Search uses original-string match offsets and does not derive offsets from lowercased
  text with different Unicode length. Multi-run phrase search is not newly implemented.
- Force Dark is disallowed for the native document WebView and algorithmic darkening is
  explicitly disabled when supported. The app's dark background/chrome remains unchanged.

## Verification and limits

`tools/office_renderer_tests` generates its own DOCX/PPTX packages and runs the actual
bundled scripts in offline Chromium. It includes DOM, geometry, pixel, resource-lifetime,
cache, failure-path and Unicode tests. Test assets contain no private documents or fonts.
The 43-test run passed (raw output removed during the 2026-11-02 docs consolidation).

The harness injects local scripts and CSS into an offline page and stubs only the source
file transport/Flutter bridge. It does NOT emulate Android WebView, WebViewAssetLoader,
CSP execution, native Force Dark, Flutter integration or device fonts. The Gradle build,
Flutter analyzer/tests and Android FPS/memory measurements were not run because their
SDKs are absent in the preparation environment. Browser success is not an APK certification.

Preview pagination is still not Word's layout engine. Headers/footers are copied when an
additional heuristic page is made; first/even/default header switching and automatic
page-number fields are not recomputed. Table header repeating and table row splitting
across pages are not fully implemented. Note-bearing and multicolumn sections are kept
rather than being flattened, but can remain longer than a physical Word page. Missing
fonts, complex script metrics, arbitrary SmartArt/chart features, custom paths, WordArt,
OLE, advanced fills and several floating-object layouts remain compatibility limits.
Real problematic user DOCX/PPTX files were not present in the uploaded source archive.

## Primary reference material

- docx-preview project/API: https://github.com/VolodymyrBaydalka/docxjs
- PPTXjs pinned source: https://github.com/meshesha/PPTXjs/tree/v1.21.1
- DrawingML body properties: https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.drawing.bodyproperties
- Android WebSettingsCompat: https://developer.android.com/reference/androidx/webkit/WebSettingsCompat

These sources informed compatibility hooks; they do not establish complete conformance
of this preview renderer. The reproducible tests document the implemented subset.
