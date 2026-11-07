import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

/// Keep fit-width through rotation without resetting a user's manual zoom.
/// The stock smart limit (1.3) would leave side gutters on landscape phones.
const pdfReadingSizeDelegateProvider = PdfViewerSizeDelegateProviderSmart(
  smartMaxScale: 8,
  maxPagesVisible: 1,
);

/// A single edge-to-edge column, including PDFs with mixed paper sizes.
/// Only the *outer* horizontal gutters are removed; authored content and page
/// aspect ratios stay intact. Keep the existing vertical page separation.
PdfPageLayout layoutPdfReadingPages(
  List<PdfPage> pages,
  PdfViewerParams params,
) {
  if (pages.isEmpty) {
    return PdfPageLayout(pageLayouts: const <Rect>[], documentSize: Size.zero);
  }
  const gap = 12.0;
  final firstWidth = pages.first.width;
  final width = firstWidth.isFinite && firstWidth > 0 ? firstWidth : 612.0;
  var top = gap;
  final rects = <Rect>[];
  for (final page in pages) {
    final pageWidth = page.width.isFinite && page.width > 0
        ? page.width
        : width;
    final pageHeight = page.height.isFinite && page.height > 0
        ? page.height
        : pageWidth * 792 / 612;
    final height = pageHeight * (width / pageWidth);
    rects.add(Rect.fromLTWH(0, top, width, height));
    top += height + gap;
  }
  return PdfPageLayout(pageLayouts: rects, documentSize: Size(width, top));
}
