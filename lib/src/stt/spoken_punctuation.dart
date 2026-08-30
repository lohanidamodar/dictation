/// Turns spoken punctuation into the marks it names.
///
/// Someone dictating says "comma" where they want one. A recogniser writes the
/// word, because that is what it heard.
///
/// **This is for dictation only.** In a transcript of someone talking, "period"
/// is usually a period of time and "new line" is a queue — applying it there
/// corrupts the text. The pipeline therefore never turns it on by itself; it
/// belongs to a dictation surface where the user knows they are issuing
/// commands.
class SpokenPunctuation {
  const SpokenPunctuation({this.rules = defaultRules});

  final Map<String, String> rules;

  /// The phrases people actually say, mapped to what they mean.
  ///
  /// Written longest-first in intent: `exclamation mark` must be tried before
  /// `mark` would be, and [apply] sorts to guarantee it.
  static const defaultRules = <String, String>{
    'new paragraph': '\n\n',
    'new line': '\n',
    'newline': '\n',
    'full stop': '.',
    'period': '.',
    'comma': ',',
    'question mark': '?',
    'exclamation mark': '!',
    'exclamation point': '!',
    'colon': ':',
    'semicolon': ';',
    'semi colon': ';',
    'open paren': '(',
    'close paren': ')',
    'open quote': '"',
    'close quote': '"',
    'hyphen': '-',
    'dash': '—',
    'ellipsis': '…',
    'dot dot dot': '…',
  };

  /// Rewrites [text], replacing spoken punctuation with real marks.
  String apply(String text) {
    if (text.isEmpty || rules.isEmpty) return text;

    final phrases = rules.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    var out = text;
    for (final phrase in phrases) {
      final mark = rules[phrase]!;
      out = out.replaceAllMapped(
        RegExp(
          r'(?<![\p{L}\p{M}\p{N}])' +
              phrase.split(' ').map(RegExp.escape).join(r'\s+') +
              r'(?![\p{L}\p{M}\p{N}])',
          caseSensitive: false,
          unicode: true,
        ),
        (_) => mark,
      );
    }
    return _tidy(out);
  }

  /// Cleans up the spacing a substitution leaves behind.
  ///
  /// "hello comma world" becomes "hello , world" if left alone, because the
  /// word had spaces on both sides and the mark should not.
  static String _tidy(String text) {
    // replaceAll takes its replacement literally — a `$1` there is the two
    // characters, not the group.
    var out = text
        // No space before a mark that closes.
        .replaceAllMapped(RegExp(r'\s+([,.;:!?…\)])'), (m) => m[1]!)
        // No space after one that opens.
        .replaceAllMapped(RegExp(r'([\(])\s+'), (m) => m[1]!)
        // A newline swallows the spaces around it.
        .replaceAll(RegExp(r'[ \t]*\n[ \t]*'), '\n')
        // Collapse runs of spaces the substitutions created.
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ');

    // A mark followed immediately by a letter needs its space back.
    out = out.replaceAllMapped(
      RegExp(r'([,.;:!?])(?=[\p{L}])', unicode: true),
      (m) => '${m[1]} ',
    );
    return out.trim();
  }
}
