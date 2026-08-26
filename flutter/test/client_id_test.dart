import 'package:flutter_test/flutter_test.dart';
import 'package:keyda_bot/src/client_id.dart';

void main() {
  group('isValidClientId', () {
    test('accepts the shortest and longest ids the platform issues', () {
      expect(isValidClientId('kb_live_0123abcd'), isTrue); // 8 hex
      expect(isValidClientId('kb_live_${'a' * 48}'), isTrue); // 48 hex
      expect(isValidClientId('kb_live_00000000'), isTrue);
      expect(isValidClientId('kb_live_deadbeef1234'), isTrue);
    });

    test('rejects ids outside the 8-48 hex range', () {
      expect(isValidClientId('kb_live_0123abc'), isFalse); // 7
      expect(isValidClientId('kb_live_${'a' * 49}'), isFalse); // 49
      expect(isValidClientId('kb_live_'), isFalse);
    });

    test('rejects anything that is not lowercase hex', () {
      expect(isValidClientId('kb_live_0123ABCD'), isFalse);
      expect(isValidClientId('kb_live_0123abcg'), isFalse);
      expect(isValidClientId('kb_live_0123-abc'), isFalse);
    });

    test('rejects other prefixes', () {
      expect(isValidClientId('kb_test_0123abcd'), isFalse);
      expect(isValidClientId('live_0123abcd'), isFalse);
      expect(isValidClientId('0123abcd'), isFalse);
      expect(isValidClientId(''), isFalse);
    });

    test('rejects copy-paste damage rather than repairing it', () {
      // Trimming here would mean the same pasted string works on Flutter and
      // fails on iOS, so the whitespace has to be reported, not absorbed.
      expect(isValidClientId(' kb_live_0123abcd'), isFalse);
      expect(isValidClientId('kb_live_0123abcd '), isFalse);
      expect(isValidClientId('kb_live_0123abcd\n'), isFalse);
    });

    test('rejects an id carrying extra path', () {
      // Otherwise this would be appended raw to the chat URL.
      expect(isValidClientId('kb_live_0123abcd/../admin'), isFalse);
      expect(isValidClientId('kb_live_0123abcd?debug=1'), isFalse);
    });
  });

  group('validateClientId', () {
    test('returns the id untouched when it is valid', () {
      expect(validateClientId('kb_live_0123abcd'), 'kb_live_0123abcd');
    });

    test('throws with the offending value in the message', () {
      expect(
        () => validateClientId('kb_live_nope'),
        throwsA(
          isA<KeydaBotConfigError>().having(
            (KeydaBotConfigError e) => e.toString(),
            'toString',
            contains('kb_live_nope'),
          ),
        ),
      );
    });
  });

  group('buildChatUrl', () {
    test('defaults to the hosted platform', () {
      expect(
        buildChatUrl(clientId: 'kb_live_0123abcd').toString(),
        'https://keyda.in/business/chat/kb_live_0123abcd',
      );
    });

    test('tolerates trailing slashes in baseUrl', () {
      expect(
        buildChatUrl(
          clientId: 'kb_live_0123abcd',
          baseUrl: 'https://keyda.in/business/',
        ).toString(),
        'https://keyda.in/business/chat/kb_live_0123abcd',
      );
      expect(
        buildChatUrl(
          clientId: 'kb_live_0123abcd',
          baseUrl: 'https://keyda.in/business//',
        ).toString(),
        'https://keyda.in/business/chat/kb_live_0123abcd',
      );
    });

    test('keeps a host and port for staging', () {
      // 10.0.2.2 is the host machine as seen from the Android emulator.
      expect(
        buildChatUrl(
          clientId: 'kb_live_0123abcd',
          baseUrl: 'http://10.0.2.2:8080',
        ).toString(),
        'http://10.0.2.2:8080/chat/kb_live_0123abcd',
      );
    });

    test('keeps a path prefix for a self-hosted install', () {
      expect(
        buildChatUrl(
          clientId: 'kb_live_0123abcd',
          baseUrl: 'https://acme.example/support/',
        ).toString(),
        'https://acme.example/support/chat/kb_live_0123abcd',
      );
    });

    test('survives whitespace around a pasted baseUrl', () {
      expect(
        buildChatUrl(
          clientId: 'kb_live_0123abcd',
          baseUrl: '  https://keyda.in/business  ',
        ).toString(),
        'https://keyda.in/business/chat/kb_live_0123abcd',
      );
    });

    test('rejects a bad client id before it can reach a URL', () {
      expect(
        () => buildChatUrl(clientId: 'kb_live_BAD'),
        throwsA(isA<KeydaBotConfigError>()),
      );
    });

    test('rejects a baseUrl no WebView could load', () {
      for (final String bad in <String>[
        'keyda.in/business', // no scheme
        'ftp://keyda.in/business',
        'file:///tmp/chat.html',
        'https://',
        '',
      ]) {
        expect(
          () => buildChatUrl(clientId: 'kb_live_0123abcd', baseUrl: bad),
          throwsA(isA<KeydaBotConfigError>()),
          reason: 'expected "$bad" to be rejected',
        );
      }
    });

    test('rejects a baseUrl whose query or fragment would be dropped', () {
      expect(
        () => buildChatUrl(
          clientId: 'kb_live_0123abcd',
          baseUrl: 'https://keyda.in/business?env=staging',
        ),
        throwsA(isA<KeydaBotConfigError>()),
      );
      expect(
        () => buildChatUrl(
          clientId: 'kb_live_0123abcd',
          baseUrl: 'https://keyda.in/business#top',
        ),
        throwsA(isA<KeydaBotConfigError>()),
      );
    });
  });

  group('staysInChat', () {
    final Uri chat = buildChatUrl(clientId: 'kb_live_0123abcd');

    test('the chat page itself, and its query or fragment, stay', () {
      expect(staysInChat(Uri.parse('https://keyda.in/business/chat/kb_live_0123abcd'), chat), isTrue);
      expect(staysInChat(Uri.parse('https://keyda.in/business/chat/kb_live_0123abcd?preview=a.b'), chat), isTrue);
      expect(staysInChat(Uri.parse('https://keyda.in/business/chat/kb_live_0123abcd#top'), chat), isTrue);
      // An explicit default port is still the same place.
      expect(staysInChat(Uri.parse('https://keyda.in:443/business/chat/kb_live_0123abcd'), chat), isTrue);
      // Host case is not part of the identity of a host.
      expect(staysInChat(Uri.parse('https://KEYDA.IN/business/chat/kb_live_0123abcd'), chat), isTrue);
    });

    test('the real Powered by Keyda link leaves', () {
      // The whole reason this check compares PATHS. The widget builds this
      // link from its own script origin, so on the default deployment it is
      // the SAME ORIGIN as the chat — an origin comparison says "ours", the
      // WebView navigates in place, and the conversation is gone.
      //
      // The earlier version of this test asserted against https://keyda.in/,
      // which is not the link the widget renders. It passed while the bug was
      // live.
      expect(staysInChat(Uri.parse('https://keyda.in/business/'), chat), isFalse);
      expect(staysInChat(Uri.parse('https://keyda.in/business/pricing'), chat), isFalse);
      expect(staysInChat(Uri.parse('https://keyda.in/business/docs/quickstart'), chat), isFalse);
    });

    test('another bot on the same host leaves', () {
      expect(staysInChat(Uri.parse('https://keyda.in/business/chat/kb_live_ffffffff'), chat), isFalse);
    });

    test('a path that merely starts with the chat path leaves', () {
      expect(staysInChat(Uri.parse('https://keyda.in/business/chat/kb_live_0123abcdEXTRA'), chat), isFalse);
    });

    test('look-alike origins leave', () {
      expect(staysInChat(Uri.parse('http://keyda.in/business/chat/kb_live_0123abcd'), chat), isFalse);
      expect(staysInChat(Uri.parse('https://keyda.in/business.evil.example/chat/kb_live_0123abcd'), chat), isFalse);
      expect(staysInChat(Uri.parse('https://keyda.in/business:8443/chat/kb_live_0123abcd'), chat), isFalse);
    });

    test('non-web and relative targets leave', () {
      expect(staysInChat(Uri.parse('mailto:owner@example.com'), chat), isFalse);
      expect(staysInChat(Uri.parse('tel:+919876543210'), chat), isFalse);
      expect(staysInChat(Uri.parse('/chat/kb_live_0123abcd'), chat), isFalse);
    });

    test('compares against whichever baseUrl was configured', () {
      final Uri staging = buildChatUrl(
        clientId: 'kb_live_0123abcd',
        baseUrl: 'http://10.0.2.2:8080',
      );
      expect(staysInChat(Uri.parse('http://10.0.2.2:8080/chat/kb_live_0123abcd'), staging), isTrue);
      expect(staysInChat(Uri.parse('http://10.0.2.2:8080/marketing'), staging), isFalse);
      expect(staysInChat(Uri.parse('https://keyda.in/business/chat/kb_live_0123abcd'), staging), isFalse);
    });
  });

  group('isInternalScheme', () {
    test('names only the schemes the WebView uses on its own', () {
      expect(isInternalScheme('about'), isTrue);
      expect(isInternalScheme('data'), isTrue);
      expect(isInternalScheme('blob'), isTrue);
      expect(isInternalScheme('javascript'), isTrue);
      expect(isInternalScheme('JavaScript'), isTrue);
    });

    test('leaves links a person could follow to the host app', () {
      expect(isInternalScheme('https'), isFalse);
      expect(isInternalScheme('mailto'), isFalse);
      expect(isInternalScheme('tel'), isFalse);
      expect(isInternalScheme('whatsapp'), isFalse);
      expect(isInternalScheme('upi'), isFalse);
    });
  });
}
