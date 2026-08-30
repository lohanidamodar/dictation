import 'dart:io';

import 'package:dictation/dictation.dart';
import 'package:test/test.dart';

void main() {
  Vocabulary of(List<VocabularyEntry> e) => Vocabulary(e);

  group('corrections', () {
    test('fixes the acronym the recogniser actually got wrong', () {
      // Verbatim from a real transcript: "Harvard and MIT, Stanford, IIT,
      // Oxford, LSC" — the school is LSE.
      final v = of([
        const VocabularyEntry(heard: ['LSC'], replacement: 'LSE'),
      ]);
      expect(
        v.apply('Harvard and MIT, Stanford, IIT, Oxford, LSC, and others'),
        'Harvard and MIT, Stanford, IIT, Oxford, LSE, and others',
      );
    });

    test('catches several spellings of the same mistake', () {
      // A recogniser is wrong in more than one way about the same word.
      final v = of([
        const VocabularyEntry(
          heard: ['Kubernetties', 'coober netties', 'Cooper Nettie'],
          replacement: 'Kubernetes',
        ),
      ]);
      for (final wrong in const [
        'we deploy on Kubernetties today',
        'we deploy on coober netties today',
        'we deploy on Cooper Nettie today',
      ]) {
        expect(v.apply(wrong), 'we deploy on Kubernetes today');
      }
    });

    test('ignores case unless told otherwise', () {
      final v = of([
        const VocabularyEntry(heard: ['dart'], replacement: 'Dart'),
      ]);
      expect(v.apply('I write dart and DART'), 'I write Dart and Dart');
    });

    test('honours case sensitivity when it matters', () {
      // "IT" the department against "it" the pronoun.
      final v = of([
        const VocabularyEntry(
          heard: ['IT'],
          replacement: 'information technology',
          caseSensitive: true,
        ),
      ]);
      expect(
        v.apply('IT said it was fine'),
        'information technology said it was fine',
      );
    });
  });

  group('boundaries', () {
    test('never rewrites part of a word', () {
      // The failure that makes a naive replace unusable.
      final v = of([
        const VocabularyEntry(heard: ['cat'], replacement: 'dog'),
      ]);
      expect(v.apply('the category of cats and one cat'),
          'the category of cats and one dog');
    });

    test('does not fire inside a Devanagari word', () {
      // \b is defined on ASCII, so it lands mid-word in Devanagari and would
      // let a correction eat half a syllable cluster.
      final v = of([
        const VocabularyEntry(heard: ['राम'], replacement: 'Ram'),
      ]);
      expect(v.apply('रामायण भन्ने कथा'), 'रामायण भन्ने कथा');
      expect(v.apply('राम आयो'), 'Ram आयो');
    });

    test('treats a following matra as part of the word', () {
      final v = of([
        const VocabularyEntry(heard: ['नेपाल'], replacement: 'Nepal'),
      ]);
      // नेपालको carries a suffix; it is not the bare word.
      expect(v.apply('नेपालको राजधानी'), 'नेपालको राजधानी');
      expect(v.apply('नेपाल राम्रो छ'), 'Nepal राम्रो छ');
    });

    test('does not fire inside a number', () {
      final v = of([
        const VocabularyEntry(heard: ['30'], replacement: 'thirty'),
      ]);
      expect(v.apply('room 304 at 30 past'), 'room 304 at thirty past');
    });
  });

  group('phrases', () {
    test('matches across whatever spacing the recogniser chose', () {
      final v = of([
        const VocabularyEntry(
          heard: ['machine learning'],
          replacement: 'ML',
        ),
      ]);
      expect(v.apply('machine  learning works'), 'ML works');
      expect(v.apply('machine\nlearning works'), 'ML works');
    });

    test('the longer phrase wins over a shorter one', () {
      final v = of([
        const VocabularyEntry(heard: ['machine'], replacement: 'engine'),
        const VocabularyEntry(
          heard: ['machine learning'],
          replacement: 'ML',
        ),
      ]);
      expect(v.apply('machine learning'), 'ML');
    });
  });

  group('robustness', () {
    test('an empty vocabulary changes nothing', () {
      expect(Vocabulary.empty().apply('unchanged'), 'unchanged');
    });

    test('entries with nothing to match or replace are skipped', () {
      final v = of([
        const VocabularyEntry(heard: [''], replacement: 'x'),
        const VocabularyEntry(heard: ['y'], replacement: ''),
      ]);
      expect(v.apply('y and things'), 'y and things');
    });

    test('a phrase with regex characters is matched literally', () {
      final v = of([
        const VocabularyEntry(heard: ['C++'], replacement: 'C plus plus'),
      ]);
      expect(v.apply('I write C++ daily'), 'I write C plus plus daily');
    });
  });

  group('persistence', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('vocab'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('survives a round trip', () async {
      final v = of([
        const VocabularyEntry(heard: ['LSC', 'else see'], replacement: 'LSE'),
        const VocabularyEntry(
          heard: ['IT'],
          replacement: 'IT',
          caseSensitive: true,
        ),
      ]);
      final path = '${dir.path}/vocab.json';
      await v.save(path);

      final back = await Vocabulary.load(path);
      expect(back.entries.length, 2);
      expect(back.entries.first.heard, ['LSC', 'else see']);
      expect(back.entries.last.caseSensitive, isTrue);
    });

    test('a missing file is an empty vocabulary, not a failure', () async {
      // The words are a convenience; losing them must not stop a run.
      expect((await Vocabulary.load('${dir.path}/none.json')).isEmpty, isTrue);
    });

    test('a corrupt file is an empty vocabulary, not a crash', () async {
      final path = '${dir.path}/bad.json';
      File(path).writeAsStringSync('{ not json');
      expect((await Vocabulary.load(path)).isEmpty, isTrue);
    });
  });
}
