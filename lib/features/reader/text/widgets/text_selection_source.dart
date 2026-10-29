import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../data/text_document.dart';
import '../logic/markdown_selection_text.dart';

/// Mounted chunks provide source offsets without materializing a lazy document.
/// The selection owner retains endpoint snapshots when an anchor scrolls away.
class TextSelectionSourceRegistry {
  final _chunks = <_TextSelectionSourceChunkState>{};

  Iterable<_TextSelectionSourceChunkState> get _activeChunks {
    final concrete = _chunks.where((chunk) => !chunk.widget.fallback);
    return concrete.isEmpty ? _chunks : concrete;
  }

  bool get hasChunks => _chunks.isNotEmpty;

  /// At a seam, a lower boundary belongs to the next chunk and an upper
  /// boundary to the preceding chunk. Do not mistake its neighbor for it.
  bool containsSourceOffset(int offset, {bool upstream = false}) =>
      _activeChunks.any((entry) {
        final chunk = entry.widget.chunk;
        return upstream
            ? offset > chunk.startOffset && offset <= chunk.endOffset
            : offset >= chunk.startOffset && offset < chunk.endOffset;
      });

  /// Actual paragraph fragments have stable local selection geometry while
  /// ancestor scroll transforms change. Aggregate scrollable geometry lags.
  Iterable<Selectable> get selectables sync* {
    for (final chunk in _activeChunks) {
      yield* chunk.leafSelectables;
    }
  }

  MarkdownTextRange? get selectedSourceRange {
    int? start;
    int? end;
    for (final chunk in _activeChunks) {
      final selection = chunk.sourceSelection();
      if (selection == null || selection.range.start == selection.range.end) {
        continue;
      }
      if (start == null || selection.range.start < start) {
        start = selection.range.start;
      }
      if (end == null || selection.range.end > end) end = selection.range.end;
    }
    return start == null || end == null ? null : MarkdownTextRange(start, end);
  }

  /// Read after dispatching the edge event so Flutter has resolved its glyph.
  int? sourceEndpoint(SelectionEdgeUpdateEvent event) {
    _ChunkSourceSelection? closest;
    var distance = double.infinity;
    for (final chunk in _activeChunks) {
      final candidate = chunk.sourceSelection(includeCollapsed: true);
      if (candidate == null) continue;
      final candidateDistance = chunk.distanceTo(event.globalPosition);
      if (candidateDistance < distance) {
        distance = candidateDistance;
        closest = candidate;
      }
    }
    if (closest == null) return null;
    final isEnd = event.type == SelectionEventType.endEdgeUpdate;
    return isEnd == closest.forward ? closest.range.end : closest.range.start;
  }
}

class TextSelectionSourceScope extends InheritedWidget {
  const TextSelectionSourceScope({
    required this.registry,
    required super.child,
    super.key,
  });

  final TextSelectionSourceRegistry registry;

  static TextSelectionSourceRegistry? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<TextSelectionSourceScope>()
      ?.registry;

  @override
  bool updateShouldNotify(TextSelectionSourceScope oldWidget) =>
      !identical(registry, oldWidget.registry);
}

/// Labels a native selectable subtree with its lazy source chunk. A fallback
/// wrapper supports callers supplying a single MarkdownBody directly; real
/// reader chunks take precedence over it in their shared registry.
class TextSelectionSourceChunk extends StatefulWidget {
  const TextSelectionSourceChunk({
    required this.chunk,
    required this.isMarkdown,
    required this.child,
    this.fallback = false,
    super.key,
  });

  final TextDocumentChunk chunk;
  final bool isMarkdown;
  final Widget child;
  final bool fallback;

  @override
  State<TextSelectionSourceChunk> createState() =>
      _TextSelectionSourceChunkState();
}

class _TextSelectionSourceChunkState extends State<TextSelectionSourceChunk> {
  final _containerKey = GlobalKey();
  TextSelectionSourceRegistry? _registry;
  MarkdownSourceMap? _map;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final registry = TextSelectionSourceScope.maybeOf(context);
    if (identical(registry, _registry)) return;
    _registry?._chunks.remove(this);
    _registry = registry;
    _registry?._chunks.add(this);
  }

  @override
  void didUpdateWidget(TextSelectionSourceChunk oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.chunk, oldWidget.chunk) ||
        widget.isMarkdown != oldWidget.isMarkdown) {
      _map = null;
    }
  }

  Iterable<_ParagraphPiece> get _pieces sync* {
    final root = _containerKey.currentContext?.findRenderObject();
    if (root == null || !root.attached) return;
    Iterable<_ParagraphPiece> visit(RenderObject object) sync* {
      final children = <RenderObject>[];
      object.visitChildren(children.add);
      if (object is! RenderParagraph) {
        for (final child in children) {
          yield* visit(child);
        }
        return;
      }
      final registrar = object.registrar;
      final leaves = registrar is MultiSelectableSelectionContainerDelegate
          ? registrar.selectables
                .where(object.selectableBelongsToParagraph)
                .toList()
          : const <Selectable>[];
      final text = object.text.toPlainText(includeSemanticsLabels: false);
      var start = 0;
      var childIndex = 0;
      while (start < text.length) {
        final placeholder = text.indexOf('\uFFFC', start);
        final end = placeholder < 0 ? text.length : placeholder;
        if (end > start && leaves.isNotEmpty) {
          yield _ParagraphPiece(
            object,
            text.substring(start, end),
            start,
            leaves,
          );
        }
        if (placeholder < 0) break;
        if (childIndex < children.length) {
          yield* visit(children[childIndex++]);
        }
        start = placeholder + 1;
      }
      while (childIndex < children.length) {
        yield* visit(children[childIndex++]);
      }
    }

    yield* visit(root);
  }

  Iterable<Selectable> get leafSelectables sync* {
    final seen = <Selectable>{};
    for (final piece in _pieces) {
      for (final leaf in piece.leaves) {
        if (seen.add(leaf)) yield leaf;
      }
    }
  }

  _ChunkSourceSelection? sourceSelection({bool includeCollapsed = false}) {
    final pieces = _pieces.toList();
    if (!pieces.any(
      (piece) => piece.leaves.any((leaf) => leaf.getSelection() != null),
    )) {
      return null;
    }
    try {
      final chunk = widget.chunk;
      final source = '${chunk.renderPrefix}${chunk.text}${chunk.renderSuffix}';
      final map = widget.isMarkdown
          ? (_map ??= MarkdownSourceMap.parse(source))
          : null;
      var from = 0;
      int? selectedStart;
      int? selectedEnd;
      bool? forward;
      for (final piece in pieces) {
        final located = map?.locateText(piece.text, from: from);
        final plainOffset = map == null ? source.indexOf(piece.text, from) : -1;
        final location =
            located ??
            (plainOffset < 0
                ? null
                : MarkdownTextRange(
                    plainOffset,
                    plainOffset + piece.text.length,
                  ));
        if (location == null) continue;
        from = location.end;
        for (final leaf in piece.leaves) {
          final selection = leaf.getSelection();
          if (selection == null) continue;
          final rawStart = selection.startOffset;
          final rawEnd = selection.endOffset;
          final lower = rawStart < rawEnd ? rawStart : rawEnd;
          final upper = rawStart > rawEnd ? rawStart : rawEnd;
          if (upper < piece.paragraphOffset ||
              lower > piece.paragraphOffset + piece.text.length) {
            continue;
          }
          if (!includeCollapsed && lower == upper) continue;
          final start =
              location.start +
              (lower - piece.paragraphOffset).clamp(0, piece.text.length);
          final end =
              location.start +
              (upper - piece.paragraphOffset).clamp(0, piece.text.length);
          if (selectedStart == null || start < selectedStart) {
            selectedStart = start;
          }
          if (selectedEnd == null || end > selectedEnd) selectedEnd = end;
          forward ??= rawEnd >= rawStart;
        }
      }
      if (selectedStart == null || selectedEnd == null) return null;
      final range =
          map?.sourceRange(selectedStart, selectedEnd) ??
          MarkdownTextRange(selectedStart, selectedEnd);
      final prefix = chunk.renderPrefix.length;
      return _ChunkSourceSelection(
        MarkdownTextRange(
          chunk.startOffset +
              (range.start - prefix).clamp(0, chunk.text.length),
          chunk.startOffset + (range.end - prefix).clamp(0, chunk.text.length),
        ),
        forward ?? true,
      );
    } on FormatException catch (error) {
      debugPrint('Folio Markdown selection source mapping failed: $error');
      return null;
    }
  }

  double distanceTo(Offset globalPosition) {
    var distance = double.infinity;
    for (final leaf in leafSelectables) {
      if (leaf.getSelection() == null) continue;
      final transform = leaf.getTransformTo(null);
      for (final box in leaf.boundingBoxes) {
        final rect = MatrixUtils.transformRect(transform, box);
        final dx = globalPosition.dx < rect.left
            ? rect.left - globalPosition.dx
            : globalPosition.dx > rect.right
            ? globalPosition.dx - rect.right
            : 0.0;
        final dy = globalPosition.dy < rect.top
            ? rect.top - globalPosition.dy
            : globalPosition.dy > rect.bottom
            ? globalPosition.dy - rect.bottom
            : 0.0;
        final squared = dx * dx + dy * dy;
        if (squared < distance) distance = squared;
      }
    }
    return distance;
  }

  @override
  void dispose() {
    _registry?._chunks.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      KeyedSubtree(key: _containerKey, child: widget.child);
}

class _ParagraphPiece {
  const _ParagraphPiece(
    this.paragraph,
    this.text,
    this.paragraphOffset,
    this.leaves,
  );

  final RenderParagraph paragraph;
  final String text;
  final int paragraphOffset;
  final List<Selectable> leaves;
}

class _ChunkSourceSelection {
  const _ChunkSourceSelection(this.range, this.forward);

  final MarkdownTextRange range;
  final bool forward;
}
