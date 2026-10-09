import 'dart:convert';

import 'package:flutter/foundation.dart';

/// `KeydaBot.setVisitor`'s details, cleaned the way the chat page cleans them,
/// so a value the page would drop never leaves the app either.
///
/// A value that does not look like what it claims is dropped whole, never cut:
/// a phone number or an email with its end cut off is a wrong one, offered to
/// the customer as if it were theirs.
@immutable
class KeydaVisitor {
  const KeydaVisitor._(this.name, this.phone, this.email);

  static final RegExp _controls = RegExp(r'[\x00-\x1f\x7f]+');
  static final RegExp _spaces = RegExp(r'\s+');

  /// Trimmed by `\s`, the page's own whitespace: Dart's `trim()` also takes
  /// characters JavaScript's keeps (U+0085), and the two must agree.
  static final RegExp _ends = RegExp(r'^\s+|\s+$');
  static final RegExp _phone = RegExp(r'^\+?[0-9() .-]{8,32}$');
  static final RegExp _nonDigit = RegExp(r'\D');
  static final RegExp _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@.]{2,}$');

  /// Null when nothing usable is left — the same as no visitor at all.
  static KeydaVisitor? of({String? name, String? phone, String? email}) {
    final String n = cleanName(name);
    final String p = cleanPhone(phone);
    final String e = cleanEmail(email);
    if (n.isEmpty && p.isEmpty && e.isEmpty) {
      return null;
    }
    return KeydaVisitor._(n, p, e);
  }

  /// One line of 1–80 characters, or empty. Control characters become a
  /// space and runs of spaces one; nothing else is taken out — a zero-width
  /// joiner, a soft hyphen or a direction mark is part of how some names are
  /// written.
  static String cleanName(String? value) {
    final String n = withoutLoneSurrogates(value ?? '')
        .replaceAll(_controls, ' ')
        .replaceAll(_spaces, ' ')
        .replaceAll(_ends, '');
    final int length = n.runes.length;
    return length >= 1 && length <= 80 ? n : '';
  }

  /// 8–15 digits — the shortest national numbers to the longest
  /// international one — with spaces and `+ - ( ) .` between them, or empty.
  /// No country code starts with 0, so "+0…" is not a number anyone has.
  static String cleanPhone(String? value) {
    final String p = (value ?? '').replaceAll(_ends, '');
    final int digits = p.replaceAll(_nonDigit, '').length;
    return _phone.hasMatch(p) && digits >= 8 && digits <= 15 && !p.startsWith('+0')
        ? p
        : '';
  }

  /// Something@somewhere.tld, up to 254 characters and with no "..", or empty.
  static String cleanEmail(String? value) {
    final String e = (value ?? '').replaceAll(_ends, '');
    return e.length <= 254 && _email.hasMatch(e) && !e.contains('..') ? e : '';
  }

  /// 1–80 characters on one line, or empty.
  final String name;

  /// 8–15 digits, with spaces and `+ - ( ) .`, or empty.
  final String phone;

  /// Up to 254 characters, or empty.
  final String email;

  /// `name=…&phone=…&email=…` for the URL's #fragment, the empty ones left out.
  List<String> fragmentItems() => <String>[
        if (name.isNotEmpty) 'name=${Uri.encodeComponent(name)}',
        if (phone.isNotEmpty) 'phone=${Uri.encodeComponent(phone)}',
        if (email.isNotEmpty) 'email=${Uri.encodeComponent(email)}',
      ];

  /// `{"name":…,"phone":…,"email":…}` for `KeydaBot.setVisitor` on the page.
  String toJson() => jsonEncode(<String, String>{'name': name, 'phone': phone, 'email': email});

  @override
  bool operator ==(Object other) =>
      other is KeydaVisitor && other.name == name && other.phone == phone && other.email == email;

  @override
  int get hashCode => Object.hash(name, phone, email);
}

/// [value] without halves of UTF-16 pairs that have lost their other half:
/// `Uri.encodeComponent` turns one into U+FFFD, and the platform channel does
/// the same, so the page would get a character nobody typed.
String withoutLoneSurrogates(String value) {
  if (!value.runes.any(_isSurrogate)) {
    return value;
  }
  return String.fromCharCodes(value.runes.where((int r) => !_isSurrogate(r)));
}

bool _isSurrogate(int rune) => rune >= 0xD800 && rune <= 0xDFFF;

/// The current visitor; every chat on screen listens.
final ValueNotifier<KeydaVisitor?> keydaVisitor = ValueNotifier<KeydaVisitor?>(null);
