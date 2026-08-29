class TextNormalization {
  /// Normalizes a word token for dictionary lookup and vocabulary saving while
  /// preserving internal apostrophes (e.g. "what's") and hyphens (e.g. "high-impact").
  static String normalizeWord(String raw) {
    if (raw.isEmpty) return '';
    String word = raw.trim();
    // Strip leading punctuation
    word = word.replaceFirst(RegExp(r"^[^a-zA-Z0-9]+"), '');
    // Strip trailing punctuation
    word = word.replaceFirst(RegExp(r"[^a-zA-Z0-9]+$"), '');
    return word.toLowerCase();
  }
}
