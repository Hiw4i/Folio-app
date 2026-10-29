import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/reader/text/logic/markdown_selection_text.dart';

void main() {
  test('inline code retains closing delimiter around longer internal runs', () {
    final map = MarkdownSourceMap.parse('Before `foo``bar` after');
    final code = map.locateText('foo``bar')!;
    expect(map.copyRange(code.start, code.end), '`foo``bar`');
  });
  test('full visible selection returns every original source byte', () {
    const source = '  # Заголовок  \r\n\r\n**Привет** &amp; 🌍\r\n';
    final map = MarkdownSourceMap.parse(source);
    expect(map.copyRange(0, map.text.length), source);
  });

  test('copies complete heading and emphasis with their source markers', () {
    final map = MarkdownSourceMap.parse('# Chapter\n\nBefore **bold** after.');
    final heading = map.locateText('Chapter')!;
    final bold = map.locateText('bold')!;
    expect(map.copyRange(heading.start, heading.end), '# Chapter');
    expect(map.copyRange(bold.start, bold.end), '**bold**');
    expect(map.copyRange(bold.start + 1, bold.end - 1), 'ol');
  });

  test('repeated labels never resolve to an earlier link destination', () {
    final map = MarkdownSourceMap.parse(
      '[same](https://same.test/same) then **same** and same',
    );
    final first = map.locateText('same')!;
    final second = map.locateText('same', from: first.end)!;
    final third = map.locateText('same', from: second.end)!;
    expect(
      map.copyRange(first.start, first.end),
      '[same](https://same.test/same)',
    );
    expect(map.copyRange(second.start, second.end), '**same**');
    expect(map.copyRange(third.start, third.end), 'same');
  });

  test('copies nested styles and Unicode using UTF16 selection offsets', () {
    final map = MarkdownSourceMap.parse('Before ***你好 🌍*** after');
    final styled = map.locateText('你好 🌍')!;
    final emoji = map.locateText('🌍')!;
    expect(map.copyRange(styled.start, styled.end), '***你好 🌍***');
    expect(map.copyRange(emoji.start, emoji.end), '🌍');
  });

  test('preserves entity and escape spellings in a partial range', () {
    final map = MarkdownSourceMap.parse(r'Before &amp; \*literal\* after');
    final entity = map.locateText('&')!;
    final literal = map.locateText('*literal*')!;
    expect(map.copyRange(entity.start, entity.end), '&amp;');
    expect(map.copyRange(literal.start, literal.end), r'\*literal\*');
  });

  test('list bullets locate to the original markers and retain nesting', () {
    final map = MarkdownSourceMap.parse(
      '- **one**\n- two\n  - nested\n\n7. seven\n8. eight\n\nEnd',
    );
    final one = map.locateText('one')!;
    final seven = map.locateText('seven')!;
    expect(map.text, contains('•'));
    expect(map.text, contains('7.'));
    expect(map.copyRange(one.start, one.end), '**one**');
    final bullet = map.locateText('•')!;
    expect(map.copyRange(bullet.start, one.end), '- **one**');
    final ordered = map.locateText('7.')!;
    expect(map.copyRange(ordered.start, seven.end), '7. seven');
  });

  test(
    'fenced code never matches the language identifier or parses markup',
    () {
      final map = MarkdownSourceMap.parse(
        'Before\n\n```dart\ndart **literal** &amp;\n```\n\nAfter',
      );
      final code = map.locateText('dart **literal** &amp;')!;
      expect(map.copyRange(code.start, code.end), 'dart **literal** &amp;');
      final block = map.locateText('dart **literal** &amp;\n')!;
      expect(
        map.copyRange(block.start, block.end),
        '```dart\ndart **literal** &amp;\n```',
      );
    },
  );

  test(
    'inline code preserves its original backticks and normalized spaces',
    () {
      final map = MarkdownSourceMap.parse('Before `` a ` b `` after');
      final code = map.locateText('a ` b')!;
      expect(map.copyRange(code.start, code.end), '`` a ` b ``');
    },
  );

  test('table cells map in row order and spanning rows preserves divider', () {
    final map = MarkdownSourceMap.parse(
      '| A | **B** |\n| --- | --- |\n| A | [B](target) |\n\nEnd',
    );
    final first = map.locateText('A')!;
    final second = map.locateText('A', from: first.end)!;
    final link = map.locateText('B', from: second.end)!;
    expect(map.copyRange(second.start, link.end), '| A | [B](target) |');
    expect(
      map.copyRange(first.start, link.end),
      '| A | **B** |\n| --- | --- |\n| A | [B](target) |',
    );
  });

  test('reference definitions do not steal matching visible text', () {
    final map = MarkdownSourceMap.parse(
      '[same]: https://same.test\n\n[same][same]\n\n**same**',
    );
    final first = map.locateText('same')!;
    final second = map.locateText('same', from: first.end)!;
    expect(map.copyRange(first.start, first.end), '[same][same]');
    expect(map.copyRange(second.start, second.end), '**same**');
  });

  test('a multiline reference title cannot steal the first visible word', () {
    final map = MarkdownSourceMap.parse(
      '[ref]: https://example.test\n  "same"\n\nsame\n\nEnd',
    );
    final word = map.locateText('same')!;
    final range = map.sourceRange(word.start, word.end);
    expect(range.start, 38);
    expect(map.copyRange(word.start, word.end), 'same');
  });

  test(
    'an empty image alt cannot map later text into its hidden destination',
    () {
      const source = '![](https://host.test/Alphabet)\n\n**Alphabet**\n\nEnd';
      final map = MarkdownSourceMap.parse(source);
      final word = map.locateText('Alphabet')!;
      expect(map.copyRange(word.start, word.end), '**Alphabet**');
      final end = map.locateText('End')!;
      expect(map.copyRange(word.start, end.end), '**Alphabet**\n\nEnd');
      expect(map.text, startsWith('External image blocked'));
    },
  );

  test('highlighted text keeps == delimiters in copied source', () {
    final map = MarkdownSourceMap.parse('Before ==marked== after.');
    final marked = map.locateText('marked')!;
    expect(map.copyRange(marked.start, marked.end), '==marked==');
    expect(map.copyRange(0, map.text.length), 'Before ==marked== after.');
  });

  test('a highlight wraps nested styling completely', () {
    final map = MarkdownSourceMap.parse('==**bold** phrase==');
    final bold = map.locateText('bold')!;
    final phrase = map.locateText('phrase')!;
    expect(map.copyRange(bold.start, phrase.end), '==**bold** phrase==');
  });

  test('cross paragraph selection preserves original intervening source', () {
    final map = MarkdownSourceMap.parse('Alpha **end**.\n\n# Next paragraph\n');
    final start = map.locateText('end')!;
    final end = map.locateText('Next')!;
    expect(map.copyRange(start.start, end.end), '**end**.\n\n# Next');
  });

  test('formatted image descriptions preserve the complete image source', () {
    const source = 'Before ![a **b**](target) after';
    final map = MarkdownSourceMap.parse(source);
    final label = map.locateText('a b')!;
    expect(map.copyRange(label.start, label.end), '![a **b**](target)');
    final after = map.locateText('after')!;
    expect(map.copyRange(after.start, after.end), 'after');
  });

  test('styled image labels never leave later text inside the destination', () {
    final map = MarkdownSourceMap.parse(
      'Before ![**same**](https://same.test) **same** after',
    );
    final image = map.locateText('same')!;
    final next = map.locateText('same', from: image.end)!;
    expect(
      map.copyRange(image.start, image.end),
      '![**same**](https://same.test)',
    );
    expect(map.copyRange(next.start, next.end), '**same**');
  });

  test(
    'escaped pipes inside table code keep their original source spelling',
    () {
      final map = MarkdownSourceMap.parse(
        '| A | Code |\n| --- | --- |\n| \\| | `b\\|c` |\n\nEnd',
      );
      final pipe = map.locateText('|')!;
      final code = map.locateText('b|c')!;
      expect(map.copyRange(pipe.start, pipe.end), r'\|');
      expect(map.copyRange(code.start, code.end), r'`b\|c`');
    },
  );

  test('blockquotes, tasks, images and unclosed fences map without drift', () {
    final map = MarkdownSourceMap.parse(
      '> **Quote**\n> next\n\n- [x] task\n\n![label](label.png)\n\n~~~\nraw',
    );
    final quote = map.locateText('Quote')!;
    final next = map.locateText('next')!;
    final task = map.locateText('task')!;
    final label = map.locateText('label')!;
    final raw = map.locateText('raw')!;
    expect(map.copyRange(quote.start, next.end), '> **Quote**\n> next');
    expect(map.copyRange(task.start, task.end), '- [x] task');
    expect(map.copyRange(label.start, label.end), '![label](label.png)');
    expect(map.copyRange(raw.start, raw.end), 'raw');
  });
}
