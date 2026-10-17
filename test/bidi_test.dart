import 'package:flutter_test/flutter_test.dart';
import 'package:gitmarker/bidi.dart';

void main() {
  group('detectDirection', () {
    test('Latin text is LTR', () {
      expect(detectDirection('Hello world'), TextDir.ltr);
    });

    test('Arabic text is RTL', () {
      expect(detectDirection('مرحبا بالعالم'), TextDir.rtl);
    });

    test('Hebrew text is RTL', () {
      expect(detectDirection('שלום'), TextDir.rtl);
    });

    test('first strong character wins over later ones', () {
      expect(detectDirection('Note: ملاحظة'), TextDir.ltr);
      expect(detectDirection('ملاحظة: note'), TextDir.rtl);
    });

    test('leading neutrals, digits and Markdown syntax are skipped', () {
      expect(detectDirection('# 12. - [ ] مهمة'), TextDir.rtl);
      expect(detectDirection('٣٤٥ apples'), TextDir.ltr);
      expect(detectDirection('**  task'), TextDir.ltr);
    });

    test('harakat and Arabic punctuation are not strong', () {
      expect(firstStrongDirection('َ،'), isNull);
      expect(detectDirection('، hello'), TextDir.ltr);
    });

    test('text without strong characters uses the fallback', () {
      expect(detectDirection(''), TextDir.ltr);
      expect(detectDirection('123 !?', fallback: TextDir.rtl), TextDir.rtl);
    });
  });

  test('directionalLines inherits direction for neutral lines', () {
    final lines = directionalLines('مرحبا\n\n123\nHello\n- ');
    expect(lines.map((l) => l.$2).toList(), [
      TextDir.rtl,
      TextDir.rtl,
      TextDir.rtl,
      TextDir.ltr,
      TextDir.ltr,
    ]);
  });

  test('normalizeForSearch folds case, diacritics and letter variants', () {
    expect(normalizeForSearch('HeLLo'), 'hello');
    expect(normalizeForSearch('مَكْتَبَة'), normalizeForSearch('مكتبه'));
    expect(normalizeForSearch('أحمد'), normalizeForSearch('احمد'));
    expect(normalizeForSearch('مـــرحبا'), normalizeForSearch('مرحبا'));
  });
}
