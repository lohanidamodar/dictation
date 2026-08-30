import 'dart:convert';
import 'dart:io';

/// One correction: what the recogniser tends to hear, and what it should be.
class VocabularyEntry {
  const VocabularyEntry({
    required this.heard,
    required this.replacement,
    this.caseSensitive = false,
  });

  /// The mis-hearings to catch. More than one because a recogniser is wrong in
  /// several different ways about the same word — `LSC`, `LSE C`, `else see`.
  final List<String> heard;

  /// What to write instead.
  final String replacement;

  /// Off by default: a recogniser's capitalisation is not evidence of
  /// anything, so matching on it would miss most of what it gets wrong.
  final bool caseSensitive;

  Map<String, dynamic> toJson() => {
        'heard': heard,
        'replacement': replacement,
        if (caseSensitive) 'caseSensitive': true,
      };

  static VocabularyEntry fromJson(Map<String, dynamic> json) => VocabularyEntry(
        heard: [
          for (final h in (json['heard'] as List? ?? const [])) '$h',
        ],
        replacement: '${json['replacement'] ?? ''}',
        caseSensitive: json['caseSensitive'] == true,
      );
}

/// Corrections applied to a transcript after recognition.
///
/// A recogniser fails on exactly the words that matter most — names, places,
/// jargon, acronyms — because they are rare in its training data and common in
/// the speaker's life. No amount of general accuracy fixes that; the model has
/// never heard of your colleague. Telling it the handful of words you actually
/// use is cheap and works immediately.
///
/// This runs after recognition rather than biasing the decoder. Biasing is
/// stronger where it is available, but it is model-specific and cannot be
/// changed without reloading; a substitution list works with every recogniser
/// here and takes effect on the next utterance.
class Vocabulary {
  Vocabulary(List<VocabularyEntry> entries)
      : entries = List.unmodifiable(entries);

  Vocabulary.empty() : entries = const [];

  final List<VocabularyEntry> entries;

  bool get isEmpty => entries.isEmpty;

  /// Rewrites [text] with every correction applied.
  ///
  /// Longer phrases are tried first, so an entry for "machine learning" is not
  /// pre-empted by one for "machine".
  String apply(String text) {
    if (entries.isEmpty || text.isEmpty) return text;

    final patterns = <(RegExp, String)>[];
    for (final entry in entries) {
      if (entry.replacement.isEmpty) continue;
      for (final heard in entry.heard) {
        final trimmed = heard.trim();
        if (trimmed.isEmpty) continue;
        patterns.add((
          RegExp(
            _bounded(trimmed),
            caseSensitive: entry.caseSensitive,
            unicode: true,
          ),
          entry.replacement,
        ));
      }
    }
    // Sort by the length of what is matched, longest first.
    patterns.sort((a, b) => b.$1.pattern.length.compareTo(a.$1.pattern.length));

    var out = text;
    for (final (pattern, replacement) in patterns) {
      out = out.replaceAll(pattern, replacement);
    }
    return out;
  }

  /// A pattern that matches [phrase] as whole words.
  ///
  /// `\b` is no use here: it is defined on ASCII word characters, so it fires
  /// in the middle of Devanagari and would let a correction rewrite half a
  /// word. Letters and combining marks are excluded on both sides instead,
  /// which behaves the same way in English and does the right thing in
  /// Devanagari — where a matra following a syllable is part of the word.
  static String _bounded(String phrase) {
    // Whitespace in the phrase should match any run of whitespace, since the
    // recogniser decides where the spaces go.
    final body = phrase
        .split(RegExp(r'\s+'))
        .map(RegExp.escape)
        .join(r'\s+');
    return r'(?<![\p{L}\p{M}\p{N}])' + body + r'(?![\p{L}\p{M}\p{N}])';
  }

  List<Map<String, dynamic>> toJson() => [for (final e in entries) e.toJson()];

  static Vocabulary fromJson(Object? json) {
    if (json is! List) return Vocabulary.empty();
    return Vocabulary([
      for (final entry in json)
        if (entry is Map<String, dynamic>) VocabularyEntry.fromJson(entry),
    ]);
  }

  /// Reads a vocabulary file, returning an empty one if it is absent.
  ///
  /// A missing or malformed file must not stop a transcription: the words are
  /// a convenience, and losing them is a smaller failure than losing the run.
  static Future<Vocabulary> load(String path) async {
    final file = File(path);
    if (!file.existsSync()) return Vocabulary.empty();
    try {
      return fromJson(jsonDecode(await file.readAsString()));
    } on FormatException {
      return Vocabulary.empty();
    }
  }

  Future<void> save(String path) async {
    await File(path).writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJson()),
    );
  }

  Vocabulary withEntry(VocabularyEntry entry) =>
      Vocabulary([...entries, entry]);
}
