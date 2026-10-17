// Bidirectional text helpers. Pure Dart: the UI maps [TextDir] onto
// Flutter's TextDirection.

enum TextDir { ltr, rtl }

/// Unicode blocks of right-to-left scripts. Only letters inside them are
/// strong RTL characters (bidi classes R and AL); combining marks, digits
/// (AN) and punctuation in these blocks are weak or neutral.
const List<(int, int)> _rtlBlocks = [
  (0x0590, 0x08FF), // Hebrew, Arabic, Syriac, Thaana, NKo, ..., Arabic Ext.
  (0xFB1D, 0xFDFF), // Hebrew + Arabic presentation forms A
  (0xFE70, 0xFEFF), // Arabic presentation forms B
  (0x10800, 0x10FFF), // Historic RTL scripts
  (0x1E800, 0x1EFFF), // Adlam, Arabic mathematical symbols, ...
];

final RegExp _letter = RegExp(r'\p{L}', unicode: true);

bool _isLetter(int rune) => _letter.hasMatch(String.fromCharCode(rune));

bool _inRtlBlock(int rune) {
  for (final (start, end) in _rtlBlocks) {
    if (rune < start) return false;
    if (rune <= end) return true;
  }
  return false;
}

bool isRtlCodePoint(int rune) => _inRtlBlock(rune) && _isLetter(rune);

bool isStrongLtrCodePoint(int rune) => !_inRtlBlock(rune) && _isLetter(rune);

/// Direction of the first strong character (rules P2/P3 of the Unicode
/// bidirectional algorithm), or null when the text has no strong character.
TextDir? firstStrongDirection(String text) {
  for (final rune in text.runes) {
    if (isRtlCodePoint(rune)) return TextDir.rtl;
    if (isStrongLtrCodePoint(rune)) return TextDir.ltr;
  }
  return null;
}

/// Direction for a block of text. Text without strong characters (empty,
/// digits, punctuation) takes [fallback].
TextDir detectDirection(String text, {TextDir fallback = TextDir.ltr}) =>
    firstStrongDirection(text) ?? fallback;

/// Splits [text] into lines and resolves a direction per line. Lines without
/// strong characters inherit the previous line's direction (or the
/// direction of the whole text for leading neutral lines), so blank lines
/// and number-only lines do not flip alignment.
List<(String, TextDir)> directionalLines(String text) {
  final base = detectDirection(text);
  var current = base;
  final result = <(String, TextDir)>[];
  for (final line in text.split('\n')) {
    current = firstStrongDirection(line) ?? current;
    result.add((line, current));
  }
  return result;
}

/// Arabic tashkeel (harakat, tanween, shadda, sukun, superscript alef, ...)
/// and the tatweel character.
final RegExp _arabicDiacritics = RegExp('[ؐ-ًؚ-ٰٟۖ-ۜ۟-۪ۨ-ۭـ]');

/// Normalizes text for search: lower case, Arabic diacritics and tatweel
/// removed, and common Arabic letter variants folded (alef forms, alef
/// maqsura, taa marbuta). Searching "مكتبة" then finds "مَكْتَبَه".
String normalizeForSearch(String text) {
  return text
      .toLowerCase()
      .replaceAll(_arabicDiacritics, '')
      .replaceAll(RegExp('[آأإٱ]'), 'ا')
      .replaceAll('ى', 'ي')
      .replaceAll('ة', 'ه');
}
