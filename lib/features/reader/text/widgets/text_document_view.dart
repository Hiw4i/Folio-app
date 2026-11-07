import 'package:flutter/widgets.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as markdown;
import 'package:scroll_to_index/scroll_to_index.dart';

import '../../../../shared/theme/folio_theme.dart';
import '../../../../shared/widgets/folio_status_view.dart';
import '../../../../shared/widgets/scroll_edge_fade.dart';
import '../data/text_document.dart';
import '../../logic/reader_state.dart';
import '../logic/markdown_selection_text.dart' show HighlightSyntax;
import '../logic/text_document_renderer.dart';
import 'text_document_selection.dart';
import 'text_selection_source.dart';

const String _passiveStart = '\u{F0000}';
const String _passiveEnd = '\u{F0001}';
const String _activeStart = '\u{F0002}';
const String _activeEnd = '\u{F0003}';

final List<markdown.InlineSyntax> _searchHitSyntaxes = <markdown.InlineSyntax>[
  _SearchHitSyntax(
    tag: 'folio-search-hit',
    start: _passiveStart,
    end: _passiveEnd,
  ),
  _SearchHitSyntax(
    tag: 'folio-search-hit-active',
    start: _activeStart,
    end: _activeEnd,
  ),
];

final MarkdownElementBuilder _passiveSearchHitBuilder = _SearchHitBuilder(
  active: false,
);
final MarkdownElementBuilder _markBuilder = _MarkBuilder();
final List<markdown.InlineSyntax> _markdownInlineSyntaxes =
    <markdown.InlineSyntax>[..._searchHitSyntaxes, HighlightSyntax()];

class TextDocumentView extends StatelessWidget {
  const TextDocumentView({
    required this.renderer,
    required this.scrollController,
    required this.activeHitKey,
    this.onSelectionChanged,
    super.key,
  });

  final TextDocumentRenderer renderer;
  final AutoScrollController scrollController;
  final GlobalKey activeHitKey;
  final ValueChanged<bool>? onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    // `close()` may clear content while this view is still mounted (e.g. a
    // fast document switch). Fall back to the empty state instead of throwing.
    final content = renderer.content;
    if (content == null || content.chunks.isEmpty) {
      return const _EmptyDocument();
    }
    final activeChunk = renderer.activeHit?.chunkIndex;
    return TextDocumentSelection(
      document: content,
      scrollController: scrollController,
      onSelectionChanged: onSelectionChanged,
      child: ScrollEdgeFade(
        color: context.colors.background,
        child: ListView.builder(
          key: const ValueKey<String>('reader_content'),
          controller: scrollController,
          physics: const BouncingScrollPhysics(
            decelerationRate: ScrollDecelerationRate.fast,
          ),
          // onDrag unfocuses the selection region and text inputs, clearing
          // the selection on the first scroll update. This is a read-only
          // viewport; search owns its separate input/focus lifecycle.
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
          padding: EdgeInsets.fromLTRB(
            AppSpacing.xl,
            MediaQuery.viewPaddingOf(context).top + 104,
            AppSpacing.xl,
            MediaQuery.viewPaddingOf(context).bottom + 184,
          ),
          itemCount: content.chunks.length,
          itemBuilder: (context, index) {
            final chunk = content.chunks[index];
            final hits = renderer.hitsForChunk(index);
            return AutoScrollTag(
              key: ValueKey<String>('reader_text_chunk_$index'),
              controller: scrollController,
              index: index,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: TextSelectionSourceChunk(
                      chunk: chunk,
                      isMarkdown: content.isMarkdown,
                      child: content.isMarkdown
                          ? _MarkdownChunk(
                              chunk: chunk,
                              hits: hits,
                              activeHit: renderer.activeHit,
                              activeHitKey: index == activeChunk
                                  ? activeHitKey
                                  : null,
                            )
                          : _PlainTextChunk(
                              chunk: chunk,
                              hits: hits,
                              activeHit: renderer.activeHit,
                              activeHitKey: index == activeChunk
                                  ? activeHitKey
                                  : null,
                            ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PlainTextChunk extends StatelessWidget {
  const _PlainTextChunk({
    required this.chunk,
    required this.hits,
    required this.activeHit,
    required this.activeHitKey,
  });

  final TextDocumentChunk chunk;
  final List<ReaderSearchHit> hits;
  final ReaderSearchHit? activeHit;
  final GlobalKey? activeHitKey;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        style: AppTextStyles.reading(context),
        children: _highlightedSpans(chunk, hits, activeHit, context.colors),
      ),
      key: activeHit == null ? null : activeHitKey,
      textAlign: TextAlign.start,
    );
  }
}

/// Splits [chunk] into plain and highlighted spans. Highlight spans only
/// override the search colors and weight — size and height inherit from the
/// parent [TextSpan] style.
List<InlineSpan> _highlightedSpans(
  TextDocumentChunk chunk,
  List<ReaderSearchHit> hits,
  ReaderSearchHit? activeHit,
  AppColors colors,
) {
  if (hits.isEmpty) {
    return <InlineSpan>[TextSpan(text: chunk.text)];
  }
  final result = <InlineSpan>[];
  var cursor = 0;
  for (final hit in hits) {
    final start = (hit.startOffset - chunk.startOffset).clamp(
      cursor,
      chunk.text.length,
    );
    final end = (hit.endOffset - chunk.startOffset).clamp(
      start,
      chunk.text.length,
    );
    if (start > cursor) {
      result.add(TextSpan(text: chunk.text.substring(cursor, start)));
    }
    final active =
        identical(hit, activeHit) ||
        (activeHit?.startOffset == hit.startOffset &&
            activeHit?.endOffset == hit.endOffset);
    result.add(
      TextSpan(
        text: chunk.text.substring(start, end),
        style: TextStyle(
          color: active ? colors.activeSearchText : colors.primary,
          backgroundColor: active
              ? colors.activeSearchMatch
              : colors.searchMatch,
          fontWeight: active ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );
    cursor = end;
  }
  if (cursor < chunk.text.length) {
    result.add(TextSpan(text: chunk.text.substring(cursor)));
  }
  return result;
}

class _MarkdownChunk extends StatelessWidget {
  const _MarkdownChunk({
    required this.chunk,
    required this.hits,
    required this.activeHit,
    required this.activeHitKey,
  });

  final TextDocumentChunk chunk;
  final List<ReaderSearchHit> hits;
  final ReaderSearchHit? activeHit;
  final GlobalKey? activeHitKey;

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      data:
          '${chunk.renderPrefix}${_markedSource(chunk, hits, activeHit)}${chunk.renderSuffix}',
      // SelectableText creates an isolated editor for each Markdown block.
      // Text.rich instead registers every block with our document SelectionArea.
      selectable: false,
      softLineBreak: true,
      onTapLink: (text, href, title) {},
      imageBuilder: (uri, title, alt) => _BlockedImage(label: alt),
      inlineSyntaxes: _markdownInlineSyntaxes,
      builders: <String, MarkdownElementBuilder>{
        'folio-search-hit': _passiveSearchHitBuilder,
        'folio-search-hit-active': _SearchHitBuilder(
          active: true,
          targetKey: activeHitKey,
        ),
        'mark': _markBuilder,
      },
      styleSheet: _readerMarkdownStyleSheet(context),
    );
  }
}

String _markedSource(
  TextDocumentChunk chunk,
  List<ReaderSearchHit> hits,
  ReaderSearchHit? activeHit,
) {
  if (hits.isEmpty) {
    return chunk.text;
  }
  var result = chunk.text;
  for (final hit in hits.reversed) {
    final start = (hit.startOffset - chunk.startOffset).clamp(0, result.length);
    final end = (hit.endOffset - chunk.startOffset).clamp(start, result.length);
    final active =
        activeHit?.startOffset == hit.startOffset &&
        activeHit?.endOffset == hit.endOffset;
    result = result.replaceRange(
      start,
      end,
      '${active ? _activeStart : _passiveStart}'
      '${result.substring(start, end)}'
      '${active ? _activeEnd : _passiveEnd}',
    );
  }
  return result;
}

class _SearchHitSyntax extends markdown.InlineSyntax {
  _SearchHitSyntax({
    required this.tag,
    required String start,
    required String end,
  }) : super('${RegExp.escape(start)}((?:.|\\n)*?)${RegExp.escape(end)}');

  final String tag;

  @override
  bool onMatch(markdown.InlineParser parser, Match match) {
    parser.addNode(markdown.Element.text(tag, match.group(1)!));
    return true;
  }
}

class _MarkBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    markdown.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    return Text(
      element.textContent,
      // Single-property override: the rest merges from the parent style.
      style: const TextStyle(backgroundColor: Color(0x59D8B44A)),
    );
  }
}

class _SearchHitBuilder extends MarkdownElementBuilder {
  _SearchHitBuilder({required this.active, this.targetKey});

  final bool active;
  final GlobalKey? targetKey;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    markdown.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    return DecoratedBox(
      key: active ? targetKey : null,
      decoration: BoxDecoration(
        color: active
            ? context.colors.activeSearchMatch
            : context.colors.searchMatch,
        borderRadius: AppRadius.xsRadius,
      ),
      child: Text(
        element.textContent,
        style: TextStyle(
          color: active
              ? context.colors.activeSearchText
              : context.colors.primary,
          fontWeight: active ? FontWeight.w600 : null,
        ),
      ),
    );
  }
}

/// Text style for the markdown reader surface, derived from
/// [AppTextStyles.reading] metrics; markdown elements override single
/// properties through the named parameters instead of `copyWith` chains.
TextStyle _readerStyle(
  BuildContext context, {
  double? fontSize,
  FontWeight fontWeight = FontWeight.w400,
  FontStyle? fontStyle,
  Color? color,
  String? fontFamily,
  TextDecoration? decoration,
  Color? backgroundColor,
}) => TextStyle(
  fontFamily: fontFamily ?? 'Inter',
  fontSize: fontSize ?? 17,
  height: 1.58,
  fontWeight: fontWeight,
  fontStyle: fontStyle,
  color: color ?? context.colors.primary,
  letterSpacing: -0.05,
  decoration: decoration,
  backgroundColor: backgroundColor,
);

/// Markdown typography for the current theme: primary for content,
/// secondary for de-emphasized elements, [AppColors.border] for hairlines
/// and [AppColors.surface] for code blocks.
MarkdownStyleSheet _readerMarkdownStyleSheet(BuildContext context) {
  final colors = context.colors;
  return MarkdownStyleSheet(
    p: _readerStyle(context),
    a: _readerStyle(
      context,
      color: colors.secondary,
      decoration: TextDecoration.underline,
    ),
    h1: _readerStyle(context, fontSize: 30, fontWeight: FontWeight.w600),
    h2: _readerStyle(context, fontSize: 25, fontWeight: FontWeight.w600),
    h3: _readerStyle(context, fontSize: 21, fontWeight: FontWeight.w600),
    h4: _readerStyle(context, fontSize: 18, fontWeight: FontWeight.w600),
    h5: _readerStyle(context, fontSize: 17, fontWeight: FontWeight.w600),
    h6: _readerStyle(context, fontSize: 16, fontWeight: FontWeight.w600),
    em: _readerStyle(context, fontStyle: FontStyle.italic),
    strong: _readerStyle(context, fontWeight: FontWeight.w600),
    del: _readerStyle(context, decoration: TextDecoration.lineThrough),
    code: _readerStyle(
      context,
      fontFamily: 'monospace',
      fontSize: 15,
      backgroundColor: colors.surface,
    ),
    blockquote: _readerStyle(context, color: colors.secondary),
    blockquotePadding: const EdgeInsets.fromLTRB(16, 8, 14, 8),
    blockquoteDecoration: BoxDecoration(
      color: colors.primary.withValues(alpha: 0.04),
      border: Border(
        left: BorderSide(
          color: colors.primary.withValues(alpha: 0.30),
          width: 2,
        ),
      ),
    ),
    codeblockPadding: const EdgeInsets.all(14),
    codeblockDecoration: BoxDecoration(
      color: colors.surface,
      borderRadius: AppRadius.mdRadius,
      border: Border.all(color: colors.border, width: 0.8),
    ),
    listBullet: _readerStyle(context, color: colors.secondary),
    listIndent: 25,
    blockSpacing: 13,
    tableHead: _readerStyle(context, fontWeight: FontWeight.w600),
    tableBody: _readerStyle(context, fontSize: 15),
    tableBorder: TableBorder.all(color: colors.border, width: 0.8),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: colors.border, width: 0.8)),
    ),
  );
}

class _BlockedImage extends StatelessWidget {
  const _BlockedImage({this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: label?.isNotEmpty == true ? label : 'Blocked document image',
      child: Container(
        constraints: const BoxConstraints(minHeight: 72),
        padding: EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: context.colors.primary.withValues(alpha: 0.04),
          borderRadius: AppRadius.mdRadius,
          border: Border.all(color: context.colors.border, width: 0.8),
        ),
        alignment: Alignment.center,
        child: Text(
          label?.isNotEmpty == true ? label! : 'External image blocked',
          textAlign: TextAlign.center,
          style: AppTextStyles.metadata(context),
        ),
      ),
    );
  }
}

class _EmptyDocument extends StatelessWidget {
  const _EmptyDocument();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: AppSpacing.xxxl),
        child: FolioStatusView(
          title: 'Empty document',
          message: 'There is no text to display.',
        ),
      ),
    );
  }
}
