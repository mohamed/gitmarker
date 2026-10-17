import 'package:flutter_test/flutter_test.dart';
import 'package:gitmarker/note_models.dart';

void main() {
  test('ChecklistItem.toggle ticks and unticks one item', () {
    const body = 'Shopping\n- [ ] milk\n  * [X] eggs\n- plain item';
    expect(
      ChecklistItem.toggle(body, 1),
      'Shopping\n- [x] milk\n  * [X] eggs\n- plain item',
    );
    expect(
      ChecklistItem.toggle(body, 2),
      'Shopping\n- [ ] milk\n  * [ ] eggs\n- plain item',
    );
    // Not a checklist item, or out of range: unchanged.
    expect(ChecklistItem.toggle(body, 0), body);
    expect(ChecklistItem.toggle(body, 3), body);
    expect(ChecklistItem.toggle(body, 9), body);
    expect(ChecklistItem.toggle('- [ ] عربي', 0), '- [x] عربي');
  });

  test('ChecklistItem.parse reads indent, state and text', () {
    final open = ChecklistItem.parse('  * [ ] milk and eggs')!;
    expect((open.indent, open.done, open.text), ('  ', false, 'milk and eggs'));
    expect(ChecklistItem.parse('+ [X] done')!.done, isTrue);
    expect(ChecklistItem.parse('- plain item'), isNull);
    expect(ChecklistItem.parse('- [ ]'), isNull, reason: 'no text');
    expect(ChecklistItem.parse('[ ] no marker'), isNull);
  });
}
