import 'package:dictation/dictation.dart';
import 'package:test/test.dart';

void main() {
  const p = SpokenPunctuation();

  group('marks', () {
    test('places a comma where the word was', () {
      expect(p.apply('hello comma world'), 'hello, world');
    });

    test('ends a sentence', () {
      expect(p.apply('that is all period'), 'that is all.');
      expect(p.apply('that is all full stop'), 'that is all.');
    });

    test('handles questions and exclamations', () {
      expect(p.apply('are you sure question mark'), 'are you sure?');
      expect(p.apply('watch out exclamation mark'), 'watch out!');
    });

    test('breaks lines and paragraphs', () {
      expect(p.apply('one new line two'), 'one\ntwo');
      expect(p.apply('one new paragraph two'), 'one\n\ntwo');
    });

    test('ignores the case it was spoken in', () {
      expect(p.apply('hello COMMA world'), 'hello, world');
    });
  });

  group('phrases that overlap', () {
    test('the longer phrase wins', () {
      // "exclamation mark" must not be read as "mark" alone, nor "new
      // paragraph" as "new line" plus a stray word.
      expect(p.apply('stop exclamation mark'), 'stop!');
      expect(p.apply('a new paragraph b'), 'a\n\nb');
    });
  });

  group('spacing', () {
    test('a mark does not keep the space the word had before it', () {
      expect(p.apply('yes comma please'), 'yes, please');
    });

    test('several marks in a row read correctly', () {
      expect(
        p.apply('first comma second comma third period'),
        'first, second, third.',
      );
    });

    test('trims what is left at the ends', () {
      expect(p.apply('  hello period  '), 'hello.');
    });
  });

  group('words that merely contain a command', () {
    test('does not fire inside a longer word', () {
      // "periodic" and "commander" must survive.
      expect(p.apply('periodic table'), 'periodic table');
      expect(p.apply('the commander said'), 'the commander said');
    });

    test('leaves Devanagari alone', () {
      expect(p.apply('नेपालको राजधानी'), 'नेपालको राजधानी');
    });
  });

  group('why this is opt-in', () {
    test('it corrupts ordinary prose, which is the point of not defaulting it',
        () {
      // In a transcript of someone talking, these are ordinary words. This
      // test exists to record why the pipeline never applies this by itself.
      expect(
        p.apply('a difficult period in his life'),
        'a difficult. in his life',
      );
    });
  });

  group('custom rules', () {
    test('a caller can supply its own set', () {
      const custom = SpokenPunctuation(rules: {'arrow': '→'});
      expect(custom.apply('input arrow output'), 'input → output');
      // Supplying rules replaces the defaults rather than adding to them.
      expect(custom.apply('hello comma world'), 'hello comma world');
    });

    test('a closing mark loses the space before it, an opening one after', () {
      // Which is why a custom rule producing something like ":)" comes out
      // tight against the previous word: the tidy pass cannot tell an
      // emoticon from a closing parenthesis.
      expect(p.apply('the end open paren for now close paren'),
          'the end (for now)');
    });

    test('an empty set changes nothing', () {
      const none = SpokenPunctuation(rules: {});
      expect(none.apply('hello comma world'), 'hello comma world');
    });
  });
}
