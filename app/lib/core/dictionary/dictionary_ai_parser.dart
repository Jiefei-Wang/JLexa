import 'dart:convert';

import 'dictionary_models.dart';

class DictionaryAiParser {
  static final RegExp _markdownFenceRegex = RegExp(
    r'```(?:json)?\s*([\s\S]*?)\s*```',
    multiLine: true,
  );

  static final RegExp _posLineRegex = RegExp(
    r'^(n\.|v\.|adj\.|adv\.|prep\.|conj\.|pron\.|interj\.)\s*(.*)$',
    caseSensitive: false,
  );

  static final List<RegExp> _conversationalFilterRegexes = [
    RegExp(
      r'^(?:Sure|Certainly|Here is|Here are|Of course|Hello|Hi)[^:\n]*:?\s*',
      caseSensitive: false,
    ),
    RegExp(
      r'(?:I hope this helps|Let me know if you need anything else).*$',
      caseSensitive: false,
    ),
  ];

  /// Parses the raw AI response text into a typed [DictionaryAiAnswer].
  /// [query] is the original searched word/phrase used to aid fallback heuristics.
  static DictionaryAiAnswer parse(String rawText, {String query = ''}) {
    final trimmed = rawText.trim();
    if (trimmed.isEmpty) {
      return _buildFallback(trimmed, query: query);
    }

    // 1. Try stripping markdown code fences if wrapped
    String jsonCandidate = trimmed;
    final match = _markdownFenceRegex.firstMatch(trimmed);
    if (match != null && match.groupCount >= 1) {
      jsonCandidate = match.group(1)?.trim() ?? trimmed;
    }

    // 2. Locate first '{' and last '}'
    final firstBrace = jsonCandidate.indexOf('{');
    final lastBrace = jsonCandidate.lastIndexOf('}');
    if (firstBrace != -1 && lastBrace > firstBrace) {
      final jsonSub = jsonCandidate.substring(firstBrace, lastBrace + 1);
      try {
        final decoded = jsonDecode(jsonSub);
        if (decoded is Map<String, dynamic>) {
          final type = decoded['type']?.toString().toLowerCase();
          if (type == 'word') {
            final sensesRaw = decoded['senses'];
            if (sensesRaw is List) {
              final senses = <DictionaryWordSense>[];
              for (final item in sensesRaw) {
                if (item is Map) {
                  final pos = item['partOfSpeech']?.toString().trim() ?? '';
                  final meaning = item['meaning']?.toString().trim() ?? '';
                  if (pos.isNotEmpty || meaning.isNotEmpty) {
                    senses.add(
                      DictionaryWordSense(partOfSpeech: pos, meaning: meaning),
                    );
                  }
                }
              }
              if (senses.isNotEmpty) {
                return DictionaryWordAnswer(senses: senses);
              }
            }
          } else if (type == 'phrase') {
            final explanation = decoded['explanation']?.toString().trim();
            if (explanation != null && explanation.isNotEmpty) {
              return DictionaryPhraseAnswer(explanation: explanation);
            }
          }
        }
      } catch (_) {
        // Fall through to controlled fallback
      }
    }

    // 3. Fallback: Parse non-JSON or malformed output
    return _buildFallback(trimmed, query: query);
  }

  static DictionaryAiAnswer _buildFallback(
    String rawText, {
    required String query,
  }) {
    var cleaned = rawText;
    for (final filter in _conversationalFilterRegexes) {
      cleaned = cleaned.replaceAll(filter, '').trim();
    }

    final isSingleWord = !query.trim().contains(' ') && query.trim().isNotEmpty;

    if (isSingleWord) {
      // Look for lines formatted like "v. 跑；运行"
      final lines = cleaned
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty);
      final senses = <DictionaryWordSense>[];
      for (final line in lines) {
        final m = _posLineRegex.firstMatch(line);
        if (m != null) {
          senses.add(
            DictionaryWordSense(
              partOfSpeech: m.group(1)!.toLowerCase(),
              meaning: m.group(2)!.trim(),
            ),
          );
        }
      }
      if (senses.isNotEmpty) {
        return DictionaryWordAnswer(senses: senses);
      }

      // If no pos prefix matched, wrap non-empty cleaned text into default sense
      if (cleaned.isNotEmpty) {
        return DictionaryWordAnswer(
          senses: [DictionaryWordSense(partOfSpeech: '', meaning: cleaned)],
        );
      }

      return const DictionaryWordAnswer(
        senses: [
          DictionaryWordSense(
            partOfSpeech: '',
            meaning: 'No explanation generated.',
          ),
        ],
      );
    }

    // Query is a phrase or sentence
    if (cleaned.isEmpty) {
      cleaned = 'No explanation generated.';
    }
    return DictionaryPhraseAnswer(explanation: cleaned);
  }
}
