import 'package:flutter_test/flutter_test.dart';
import 'package:keyda_bot/src/chat_page.dart';
import 'package:keyda_bot/src/visitor.dart';

/// `setVisitor`'s cleaning, which must drop exactly what the chat page drops.
void main() {
  // Built from code points: a lone half cannot be written in a source file.
  final String loneHalf = String.fromCharCode(0xD83D);
  final String grin = String.fromCharCodes(<int>[0x1F600]);
  final String joiner = String.fromCharCode(0x200D);
  final String softHyphen = String.fromCharCode(0x00AD);

  test('keeps well-formed details', () {
    final KeydaVisitor? v =
        KeydaVisitor.of(name: '  Asha \n Rao ', phone: '+91 98765 43210', email: 'asha@example.com');
    expect(v?.name, 'Asha Rao');
    expect(v?.phone, '+91 98765 43210');
    expect(v?.email, 'asha@example.com');
    expect(v?.fragmentItems(), <String>['name=Asha%20Rao', 'phone=%2B91%2098765%2043210', 'email=asha%40example.com']);
  });

  test('drops what does not look like what it claims, whole', () {
    expect(KeydaVisitor.of(name: 'a' * 81, phone: 'call me', email: 'x@y'), isNull);
    expect(KeydaVisitor.of(), isNull);
    expect(KeydaVisitor.of(name: ' \t\n '), isNull);
    expect(KeydaVisitor.of(phone: '12', email: 'a@b.co')?.phone, '');
  });

  test('name: 1 to 80 characters on one line, nothing else taken out', () {
    expect(KeydaVisitor.cleanName('a' * 80), 'a' * 80);
    expect(KeydaVisitor.cleanName('a' * 81), '', reason: 'dropped, not cut');
    expect(KeydaVisitor.cleanName(grin * 80), grin * 80, reason: 'counted in characters');
    expect(KeydaVisitor.cleanName('Asha${String.fromCharCodes(<int>[0, 1, 9])}Rao'), 'Asha Rao');
    expect(KeydaVisitor.cleanName('Asha${String.fromCharCode(0x7F)}Rao'), 'Asha Rao');
    expect(KeydaVisitor.cleanName('Asha$loneHalf Rao'), 'Asha Rao');
    expect(KeydaVisitor.cleanName('A${joiner}B${softHyphen}C'), 'A${joiner}B${softHyphen}C');
  });

  test('phone: 8 to 15 digits, and no "+0"', () {
    expect(KeydaVisitor.cleanPhone(' 9876 5432 '), '9876 5432');
    expect(KeydaVisitor.cleanPhone('987 6543'), '', reason: '7 digits');
    expect(KeydaVisitor.cleanPhone('+1 (234) 567-8901.234'), '+1 (234) 567-8901.234');
    expect(KeydaVisitor.cleanPhone('1234567890123456'), '', reason: '16 digits');
    expect(KeydaVisitor.cleanPhone('+0 98765 43210'), '');
    expect(KeydaVisitor.cleanPhone('98765 43210 ext 2'), '');
    expect(KeydaVisitor.cleanPhone('9' * 8 + ' ' * 25), '9' * 8, reason: 'trimmed first');
    expect(KeydaVisitor.cleanPhone('9  ' * 12), '', reason: '12 digits, but 34 characters');
  });

  test('email: a real-looking address up to 254 characters', () {
    expect(KeydaVisitor.cleanEmail(' asha@example.co.in '), 'asha@example.co.in');
    expect(KeydaVisitor.cleanEmail('asha@example.c'), '', reason: 'a one-letter ending');
    expect(KeydaVisitor.cleanEmail('asha..rao@example.com'), '');
    expect(KeydaVisitor.cleanEmail('asha@example..com'), '');
    expect(KeydaVisitor.cleanEmail('asha rao@example.com'), '');
    expect(KeydaVisitor.cleanEmail('${'a' * 242}@example.com'), '${'a' * 242}@example.com');
    expect(KeydaVisitor.cleanEmail('${'a' * 243}@example.com'), '', reason: '255 characters');
  });

  test('the start question: no lone halves, cut at 500 whole characters', () {
    expect(cleanQuestion('  Is it in stock?$loneHalf '), 'Is it in stock?');
    final String q = cleanQuestion('${'a' * 499}$grin${'b' * 10}');
    expect(q.runes.length, 500);
    expect(q.endsWith(grin), isTrue);
    expect(Uri.encodeComponent(cleanQuestion('a${loneHalf}b')), 'ab');
  });
}
