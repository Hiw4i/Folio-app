import 'package:markdown/markdown.dart' as markdown;

/// A half-open UTF-16 range, matching Flutter's text selection offsets.
class MarkdownTextRange {
  const MarkdownTextRange(this.start, this.end);

  final int start;
  final int end;
}

/// Maps the reader's rendered text back to the original Markdown spelling.
class MarkdownSourceMap {
  MarkdownSourceMap._(
    this.source,
    this.text,
    this._starts,
    this._ends,
    this._spans,
  );

  factory MarkdownSourceMap.parse(String source) =>
      _SourceMapBuilder(source).build();

  final String source;
  final String text;
  final List<int> _starts;
  final List<int> _ends;
  final List<_MarkdownSpan> _spans;

  /// Locate each materialized paragraph in order, carrying the previous end as
  /// [from]. Chunk-local offsets disambiguate identical text in lazy lists.
  MarkdownTextRange? locateText(String fragment, {int from = 0}) {
    RangeError.checkValueInInterval(from, 0, text.length, 'from');
    if (fragment.isEmpty) return null;
    final start = text.indexOf(fragment, from);
    return start < 0 ? null : MarkdownTextRange(start, start + fragment.length);
  }

  /// Complete syntax nodes keep their original markers. Selecting only the
  /// interior of a styled node copies that exact interior source range.
  MarkdownTextRange sourceRange(int start, int end) {
    RangeError.checkValidRange(start, end, text.length);
    if (start == end) {
      final offset = start == text.length ? source.length : _starts[start];
      return MarkdownTextRange(offset, offset);
    }
    if (start == 0 && end == text.length) {
      return MarkdownTextRange(0, source.length);
    }
    var sourceStart = _starts[start];
    var sourceEnd = _ends[end - 1];
    for (final span in _spans) {
      if (start <= span.start && end >= span.end) {
        if (span.sourceStart < sourceStart) sourceStart = span.sourceStart;
        if (span.sourceEnd > sourceEnd) sourceEnd = span.sourceEnd;
      }
    }
    return MarkdownTextRange(sourceStart, sourceEnd);
  }

  String copyRange(int start, int end) {
    final range = sourceRange(start, end);
    return source.substring(range.start, range.end);
  }
}

class _MarkdownSpan {
  const _MarkdownSpan(this.start, this.end, this.sourceStart, this.sourceEnd);

  final int start;
  final int end;
  final int sourceStart;
  final int sourceEnd;
}

/// ImageSyntax flattens its description into alt text. Retain the original
/// inline nodes so their visible characters can still map through formatting.
class _SelectionImageSyntax extends markdown.ImageSyntax {
  @override
  markdown.Element createNode(
    String destination,
    String? title, {
    required List<markdown.Node> Function() getChildren,
  }) {
    final children = getChildren();
    final image = super.createNode(
      destination,
      title,
      getChildren: () => children,
    );
    return markdown.Element('img', children)
      ..attributes.addAll(image.attributes);
  }
}

/// The mark extension: `==highlight==`. The rendered view and the selection
/// source map must hide the same markers, so both parse through this syntax.
class HighlightSyntax extends markdown.InlineSyntax {
  HighlightSyntax() : super(r'==(?=\S)(.+?)(?<=\S)==');

  @override
  bool onMatch(markdown.InlineParser parser, Match match) {
    parser.addNode(
      markdown.Element(
        'mark',
        parser.document.parseInline(match.group(1)!),
      ),
    );
    return true;
  }
}

/// The Markdown AST determines which source is visible; the monotonically
/// advancing locator then retains the spelling of each visible UTF-16 unit.
/// Links and code advance over their hidden syntax before the next node, so a
/// repeated word cannot accidentally map into a URL or a fence language tag.
class _SourceMapBuilder {
  _SourceMapBuilder(this.source);

  final String source;
  final _output = StringBuffer();
  final _starts = <int>[];
  final _ends = <int>[];
  final _spans = <_MarkdownSpan>[];
  final _listCounters = <int?>[];
  final _decoded = <int, _DecodedSource>{};
  final _entities = <String, String>{};
  int _cursor = 0;
  int _tableDepth = 0;

  MarkdownSourceMap build() {
    final document = markdown.Document(
      extensionSet: markdown.ExtensionSet.gitHubFlavored,
      inlineSyntaxes: [HighlightSyntax(), _SelectionImageSyntax()],
      encodeHtml: false,
    );
    for (final node in document.parse(source)) {
      _visit(node);
    }
    var length = _starts.length;
    while (length > 0 && _starts[length - 1] == _ends[length - 1]) {
      length--;
    }
    final text = _output.toString().substring(0, length);
    return MarkdownSourceMap._(
      source,
      text,
      _starts.sublist(0, text.length),
      _ends.sublist(0, text.length),
      _spans,
    );
  }

  void _append(String text, int start, int end) {
    _output.write(text);
    for (var i = 0; i < text.length; i++) {
      _starts.add(start);
      _ends.add(end);
    }
  }

  void _separator(String text) => _append(text, _cursor, _cursor);

  int _lineStart(int position) => source.lastIndexOf('\n', position - 1) + 1;

  int _lineEnd(int position) {
    final next = source.indexOf('\n', position);
    final end = next < 0 ? source.length : next;
    return end > 0 && source.codeUnitAt(end - 1) == 13 ? end - 1 : end;
  }

  void _skipDefinitions() {
    while (_cursor < source.length) {
      final lineEnd = _lineEnd(_cursor);
      final line = source.substring(_cursor, lineEnd);
      if (line.trim().isEmpty) {
        _cursor = lineEnd;
        if (_cursor < source.length && source[_cursor] == '\r') _cursor++;
        if (_cursor < source.length && source[_cursor] == '\n') _cursor++;
        continue;
      }
      if (!RegExp(r'^ {0,3}\[').hasMatch(line)) return;
      // Let the same parser consume reference definitions, including multiline
      // destinations and titles, rather than matching hidden words as content.
      final rawLines = source.substring(_cursor).split('\n');
      final lines = rawLines
          .map(
            (line) => markdown.Line(
              line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
            ),
          )
          .toList();
      final parser = markdown.BlockParser(lines, markdown.Document());
      const syntax = markdown.LinkReferenceDefinitionSyntax();
      if (!syntax.canParse(parser)) return;
      syntax.parse(parser);
      final consumed = parser.isDone
          ? lines.length
          : lines.indexOf(parser.current);
      if (consumed == 0) return;
      for (var i = 0; i < consumed; i++) {
        _cursor = (_cursor + rawLines[i].length + 1).clamp(0, source.length);
      }
    }
  }

  _MarkdownSpan? _visit(markdown.Node node) {
    if (node is markdown.Text) {
      return _literal(node.text);
    }
    if (node is! markdown.Element) return null;
    final tag = node.tag;
    if (tag == 'pre') return _codeBlock(node);
    if (tag == 'code') return _inlineCode(node);
    if (tag == 'br') {
      final start = _starts.length;
      final lineEnd = _lineEnd(_cursor);
      final next = source.indexOf('\n', _cursor);
      _append('\n', _cursor, next < 0 ? lineEnd : next + 1);
      _cursor = next < 0 ? lineEnd : next + 1;
      return _MarkdownSpan(start, _starts.length, _starts[start], _cursor);
    }
    if (tag == 'hr') {
      _skipDefinitions();
      _cursor = _lineEnd(_cursor);
      return null;
    }
    _skipDefinitions();
    if (tag == 'tr') _skipTableDivider();
    if (tag == 'table') _tableDepth++;
    if (tag == 'td' || tag == 'th') _skipCellPrefix();
    final start = _starts.length;
    final before = _cursor;
    int? syntaxStart;
    if (tag == 'ol' || tag == 'ul') {
      _listCounters.add(
        tag == 'ol' ? int.tryParse(node.attributes['start'] ?? '1') ?? 1 : null,
      );
    }
    if (tag == 'li') {
      final match = RegExp(
        r'[ \t]*(?:>[ \t]*)*(?:([-+*])|(\d+)[.)])[ \t]+(?:\[[ xX]\][ \t]+)?',
      ).matchAsPrefix(source, _cursor);
      if (match != null) {
        syntaxStart = match.start;
        final checkbox = source
            .substring(match.start, match.end)
            .contains(RegExp(r'\[[ xX]\]'));
        if (!checkbox) {
          final counter = _listCounters.isEmpty ? null : _listCounters.last;
          final bullet = counter == null ? '•' : '$counter.';
          _append(bullet, match.start, match.end);
          _separator(' ');
        }
        if (_listCounters.isNotEmpty && _listCounters.last != null) {
          _listCounters[_listCounters.length - 1] = _listCounters.last! + 1;
        }
        _cursor = match.end;
      }
    }
    final children = node.children ?? const <markdown.Node>[];
    final childSpans = <_MarkdownSpan>[];
    if (tag == 'img') {
      final alt = node.attributes['alt'];
      if (alt == null || alt.isEmpty) {
        final opening = source.indexOf('![]', _cursor);
        if (opening < 0) {
          throw FormatException(
            'Empty Markdown image could not be mapped',
            source,
            _cursor,
          );
        }
        final linked = _linkRange(
          before,
          opening + 2,
          opening + 2,
          image: true,
        );
        _append('External image blocked', linked.start, linked.end);
        _cursor = linked.end;
        final span = _MarkdownSpan(
          start,
          _starts.length,
          linked.start,
          linked.end,
        );
        _spans.add(span);
        return span;
      }
    }
    for (var i = 0; i < children.length; i++) {
      if (tag == 'tr' && i > 0) _separator('\t');
      final span = _visit(children[i]);
      if (span != null) childSpans.add(span);
    }
    if (tag == 'ol' || tag == 'ul') _listCounters.removeLast();
    if (tag == 'table') _tableDepth--;
    if (_starts.length == start || childSpans.isEmpty) return null;
    var sourceStart = syntaxStart ?? childSpans.first.sourceStart;
    var sourceEnd = childSpans.last.sourceEnd;
    if (tag == 'strong' || tag == 'em' || tag == 'del' || tag == 'mark') {
      final count = tag == 'em' ? 1 : 2;
      final markers = switch (tag) {
        'del' => const <String>['~'],
        'mark' => const <String>['='],
        _ => const <String>['*', '_'],
      };
      for (final marker in markers) {
        final delimiter = marker * count;
        if (sourceStart >= count &&
            source.substring(sourceStart - count, sourceStart) == delimiter &&
            source.startsWith(delimiter, sourceEnd)) {
          sourceStart -= count;
          sourceEnd += count;
          _cursor = sourceEnd;
          break;
        }
      }
    } else if (tag == 'a' || tag == 'img') {
      final linked = _linkRange(
        before,
        sourceStart,
        sourceEnd,
        image: tag == 'img',
      );
      sourceStart = linked.start;
      sourceEnd = linked.end;
      _cursor = sourceEnd;
    } else if (RegExp(r'^h[1-6]$').hasMatch(tag)) {
      sourceStart = _lineStart(sourceStart);
      sourceEnd = _lineEnd(sourceEnd);
      final next = source.indexOf('\n', sourceEnd);
      if (next >= 0 && next + 1 < source.length) {
        final nextEnd = _lineEnd(next + 1);
        if (RegExp(r'^ {0,3}(?:=+|-+)[ \t]*$')
            .hasMatch(source.substring(next + 1, nextEnd))) {
          sourceEnd = nextEnd;
        }
      }
      _cursor = sourceEnd;
    } else if (tag == 'tr') {
      sourceStart = _lineStart(sourceStart);
      sourceEnd = _lineEnd(sourceEnd);
      _cursor = sourceEnd;
    } else if (tag == 'blockquote') {
      sourceStart = _lineStart(sourceStart);
    }
    var visibleEnd = _starts.length;
    while (visibleEnd > start &&
        _starts[visibleEnd - 1] == _ends[visibleEnd - 1]) {
      visibleEnd--;
    }
    final span = _MarkdownSpan(start, visibleEnd, sourceStart, sourceEnd);
    _spans.add(span);
    if (const {
      'p',
      'li',
      'tr',
      'blockquote',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
    }.contains(tag)) {
      _separator('\n');
    }
    return span;
  }

  void _skipCellPrefix() {
    while (_cursor < source.length &&
        (source[_cursor] == ' ' || source[_cursor] == '\t')) {
      _cursor++;
    }
    if (_cursor < source.length && source[_cursor] == '|') _cursor++;
    while (_cursor < source.length &&
        (source[_cursor] == ' ' || source[_cursor] == '\t')) {
      _cursor++;
    }
  }

  void _skipTableDivider() {
    var position = _cursor;
    while (position < source.length &&
        (source[position] == '\n' || source[position] == '\r')) {
      position++;
    }
    final end = _lineEnd(position);
    if (RegExp(r'^[ \t|:\-]+$').hasMatch(source.substring(position, end))) {
      _cursor = end;
    }
  }

  MarkdownTextRange _linkRange(
    int before,
    int start,
    int end, {
    required bool image,
  }) {
    var opening = source.lastIndexOf('[', start);
    if (opening >= before && source.startsWith(']', end)) {
      if (image && opening > 0 && source[opening - 1] == '!') opening--;
      var closing = end + 1;
      if (source.startsWith('(', closing)) {
        var depth = 1;
        closing++;
        while (closing < source.length && depth > 0) {
          if (source[closing] == '\\') {
            closing = (closing + 2).clamp(0, source.length);
            continue;
          }
          if (source[closing] == '(') depth++;
          if (source[closing] == ')') depth--;
          closing++;
        }
      } else if (source.startsWith('[', closing)) {
        final referenceEnd = source.indexOf(']', closing + 1);
        if (referenceEnd >= 0) closing = referenceEnd + 1;
      }
      return MarkdownTextRange(opening, closing);
    }
    if (start > before &&
        source[start - 1] == '<' &&
        source.startsWith('>', end)) {
      return MarkdownTextRange(start - 1, end + 1);
    }
    return MarkdownTextRange(start, end);
  }

  _MarkdownSpan? _inlineCode(markdown.Element node) {
    // Match the delimiter-run rules used by markdown's CodeSyntax, including
    // the guard against closing on a suffix of a longer backtick run.
    final matches = RegExp(r'(?<!`)(`+(?!`))((?:.|\n)*?[^`])\1(?!`)')
        .allMatches(source, _cursor)
        .iterator;
    if (!matches.moveNext()) return _literal(node.textContent, raw: true);
    final match = matches.current;
    final sourceStart = match.start;
    final sourceEnd = match.end;
    final markerLength = match[1]!.length;
    final raw = match[2]!;
    var contentStart = sourceStart + markerLength;
    if (raw.trim().isNotEmpty &&
        (raw.startsWith(' ') || raw.startsWith('\n')) &&
        (raw.endsWith(' ') || raw.endsWith('\n'))) {
      contentStart++;
    }
    _cursor = contentStart;
    final start = _starts.length;
    _literal(node.textContent, raw: true, codeSpaces: true);
    _cursor = sourceEnd;
    final span = _MarkdownSpan(start, _starts.length, sourceStart, sourceEnd);
    _spans.add(span);
    return span;
  }

  _MarkdownSpan? _codeBlock(markdown.Element node) {
    _skipDefinitions();
    final before = _cursor;
    final openingEnd = _lineEnd(_cursor);
    final opening = source.substring(_cursor, openingEnd);
    final fence = RegExp(r'^[ \t]*(?:>[ \t]*)*(`{3,}|~{3,})')
        .firstMatch(opening);
    int? closingStart;
    int? closingEnd;
    if (fence != null) {
      final marker = fence[1]!;
      _cursor = source.indexOf('\n', openingEnd);
      _cursor = _cursor < 0 ? source.length : _cursor + 1;
      final closing = RegExp(
        '^[ \\t]*(?:>[ \\t]*)*${RegExp.escape(marker[0])}{${marker.length},}[ \\t]*\\r?\$',
        multiLine: true,
      ).firstMatch(source.substring(_cursor));
      if (closing != null) {
        closingStart = _cursor + closing.start;
        closingEnd = _cursor + closing.end;
      }
    }
    final start = _starts.length;
    final text = node.textContent;
    _literal(text, raw: true, limit: closingStart);
    final sourceStart = fence == null ? _lineStart(_starts[start]) : before;
    final sourceEnd = closingEnd ?? _cursor;
    _cursor = sourceEnd;
    final span = _MarkdownSpan(start, _starts.length, sourceStart, sourceEnd);
    if (_starts.length > start) _spans.add(span);
    _separator('\n');
    return span;
  }

  _MarkdownSpan? _literal(
    String text, {
    bool raw = false,
    bool codeSpaces = false,
    int? limit,
  }) {
    if (text.isEmpty) return null;
    final start = _starts.length;
    final endLimit = limit ?? source.length;
    var textIndex = 0;
    while (textIndex < text.length) {
      final lineEnd = text.indexOf('\n', textIndex);
      final partEnd = lineEnd < 0 ? text.length : lineEnd;
      final part = text.substring(textIndex, partEnd);
      if (part.isNotEmpty) {
        final decoded = _decode(raw: raw, codeSpaces: codeSpaces);
        final found = decoded.text.indexOf(part, decoded.indexAt(_cursor));
        if (found < 0 || decoded.ends[found + part.length - 1] > endLimit) {
          throw FormatException(
            'Rendered Markdown text could not be mapped to source',
            part,
            _cursor,
          );
        }
        for (var i = found; i < found + part.length; i++) {
          _append(decoded.text[i], decoded.starts[i], decoded.ends[i]);
        }
        _cursor = decoded.ends[found + part.length - 1];
      }
      if (lineEnd < 0) break;
      final newline = source.indexOf('\n', _cursor);
      if (newline >= 0 && newline < endLimit) {
        _append(
          '\n',
          newline > 0 && source[newline - 1] == '\r' ? newline - 1 : newline,
          newline + 1,
        );
        _cursor = newline + 1;
      } else {
        _append('\n', _cursor, _cursor);
      }
      textIndex = partEnd + 1;
    }
    if (_starts.length == start) return null;
    return _MarkdownSpan(start, _starts.length, _starts[start], _ends.last);
  }

  _DecodedSource _decode({required bool raw, required bool codeSpaces}) {
    final tablePipes = raw && codeSpaces && _tableDepth > 0;
    final key = (raw ? 1 : 0) | (codeSpaces ? 2 : 0) | (tablePipes ? 4 : 0);
    return _decoded.putIfAbsent(
      key,
      () => _decodeSource(
        raw: raw,
        codeSpaces: codeSpaces,
        tablePipes: tablePipes,
      ),
    );
  }

  _DecodedSource _decodeSource({
    required bool raw,
    required bool codeSpaces,
    required bool tablePipes,
  }) {
    final buffer = StringBuffer();
    final starts = <int>[];
    final ends = <int>[];
    var position = 0;
    final end = source.length;
    void append(String value, int from, int to) {
      buffer.write(value);
      for (var i = 0; i < value.length; i++) {
        starts.add(from);
        ends.add(to);
      }
    }

    while (position < end) {
      final from = position;
      var char = source[position++];
      if (char == '\r' && position < end && source[position] == '\n') {
        position++;
        char = '\n';
      }
      if (codeSpaces && char == '\n') char = ' ';
      if (char == '\\' &&
          position < end &&
          ((!raw &&
                  RegExp(r'[!"#$%&\x27()*+,\-./:;<=>?@\[\]\\^_`{|}~]')
                      .hasMatch(source[position])) ||
              (tablePipes && source[position] == '|'))) {
        char = source[position++];
      } else if (!raw && char == '&') {
        final entity = RegExp(
          r'&(?:#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]+);',
        ).matchAsPrefix(source, from);
        if (entity != null && entity.end <= end) {
          final value = _entities.putIfAbsent(
            entity[0]!,
            () =>
                markdown.Document(encodeHtml: false)
                    .parseInline(entity[0]!)
                    .map((n) => n.textContent)
                    .join(),
          );
          char = value;
          position = entity.end;
        }
      }
      append(char, from, position);
    }
    return _DecodedSource(buffer.toString(), starts, ends);
  }
}

class _DecodedSource {
  const _DecodedSource(this.text, this.starts, this.ends);

  final String text;
  final List<int> starts;
  final List<int> ends;

  int indexAt(int sourceOffset) {
    var low = 0;
    var high = starts.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (starts[middle] < sourceOffset) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }
}

/// Plain-text projection for consumers explicitly requesting rendered content.
/// Reader clipboard operations preserve source through [MarkdownSourceMap]
/// instead; full-document Copy reads the original document verbatim.
String markdownSelectionText(String source) {
  final document = markdown.Document(
    extensionSet: markdown.ExtensionSet.gitHubFlavored,
    inlineSyntaxes: [HighlightSyntax()],
    encodeHtml: false,
  );
  final nodes = document.parseLines(source.split('\n'));
  final output = StringBuffer();
  void write(markdown.Node node) {
    if (node is markdown.Text) {
      output.write(node.text);
      return;
    }
    if (node is! markdown.Element) return;
    if (node.tag == 'br') {
      output.writeln();
      return;
    }
    if (node.tag == 'img') {
      output.write(node.attributes['alt'] ?? 'External image blocked');
      return;
    }
    final children = node.children ?? const <markdown.Node>[];
    for (var i = 0; i < children.length; i++) {
      if (node.tag == 'tr' && i > 0) output.write('\t');
      write(children[i]);
    }
    if (const <String>{
      'p',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'li',
      'pre',
      'tr',
      'blockquote',
      'hr',
    }.contains(node.tag)) {
      output.writeln();
    }
  }

  for (final node in nodes) {
    write(node);
  }
  return output.toString().trimRight();
}
