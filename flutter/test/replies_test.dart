import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keyda_bot/src/replies.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The reply check against a stand-in for `/widget/{clientId}/messages`.
///
/// One watcher serves the whole app, so the tests share it; each starts it
/// for a bot of its own, which starts afresh.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test answers every HttpClient request with a 400; this test talks
  // to its own loopback server.
  HttpOverrides.global = null;

  const String chat = '1fe085d4-e386-4200-893c-237e021b2308';
  const String asked = '2026-10-09T15:00:00.000Z';
  const String reply = '2026-10-09T15:54:41.019Z';
  late HttpServer server;
  List<Map<String, String>> rows = <Map<String, String>>[];
  int calls = 0;
  String? lastAfter;
  Duration delay = Duration.zero;

  Uri chatUrl(String clientId) =>
      Uri.parse('http://127.0.0.1:${server.port}/business/chat/$clientId');

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      calls++;
      lastAfter = request.uri.queryParameters['after'];
      final String after = lastAfter ?? '';
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(<String, Object>{
        'messages': rows.where((Map<String, String> r) => r['at']!.compareTo(after) > 0).toList(),
      }));
      await request.response.close();
    });
  });

  tearDownAll(() => server.close(force: true));

  Future<Map<String, Object?>> stored(String clientId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return jsonDecode(prefs.getString('keyda_bot_waits_$clientId')!) as Map<String, Object?>;
  }

  test('a reply while the chat is closed: unread, told once, cleared by the page', () async {
    const String clientId = 'kb_live_98379989acbdf20bd9deaa8f';
    final KeydaReplies replies = KeydaReplies.instance;
    int told = 0;
    replies.onReply = () => told++;
    replies.start(chatUrl(clientId), clientId);
    await replies.look(forced: false);
    expect(calls, 0, reason: 'nothing is waited on yet');

    final int now = DateTime.now().millisecondsSinceEpoch;
    replies.onWaits(<Object>[
      <String, Object>{'c': chat, 'at': '', 't': now},
      <String, Object>{'c': 'not-a-chat', 'at': '', 't': now},
      <String, Object>{'c': chat.replaceFirst('1f', '2f'), 'at': '', 't': now - const Duration(days: 15).inMilliseconds},
    ], chatUrl: chatUrl(clientId), fromOnScreen: true);
    rows = <Map<String, String>>[
      <String, String>{'from': 'user', 'at': '2026-10-09T15:54:09.192Z'},
      <String, String>{'from': 'human', 'at': reply},
    ];
    await replies.look(forced: false);
    expect(calls, 1, reason: 'one chat survives the checks: one request');
    expect(replies.unread.value, isTrue);
    expect(told, 1);

    await replies.look(forced: false);
    await replies.look(forced: true);
    expect(calls, 1, reason: 'once a minute; forced, once every 10 seconds');

    expect(((await stored(clientId))['waits']! as List<Object?>).length, 1);

    replies.chatAppeared();
    await pumpEventQueue();
    expect(replies.unread.value, isFalse, reason: 'the chat is showing it');
    await replies.look(forced: true);
    expect(calls, 1, reason: 'no request while a chat is on screen');

    // The chat failed to load, so the page never moved its place.
    replies.chatWentAway();
    await replies.look(forced: false);
    expect(replies.unread.value, isTrue);

    // The page drew it and sent its new place.
    replies.chatAppeared();
    await pumpEventQueue();
    replies.onWaits(<Object>[
      <String, Object>{'c': chat, 'at': reply, 't': now},
    ], chatUrl: chatUrl(clientId), fromOnScreen: true);
    replies.chatWentAway();
    await replies.look(forced: false);
    expect(replies.unread.value, isFalse);
    expect(told, 1, reason: 'told once per reply');
    replies.onReply = null;
  });

  test("a chat out of sight: only a person's reply lights the dot", () async {
    const String clientId = 'kb_live_0123456789abcdef01234567';
    const String order = '2026-10-09T15:30:00.000Z';
    final KeydaReplies replies = KeydaReplies.instance;
    int told = 0;
    replies.onReply = () => told++;
    replies.start(chatUrl(clientId), clientId);
    final int now = DateTime.now().millisecondsSinceEpoch;
    List<Object> waitsAt(String at) => <Object>[
          <String, Object>{'c': chat, 'at': at, 't': now},
        ];

    // Asked for a person in a chat on screen, then left it in a tab that is
    // not selected, where the page drew an order's new status.
    replies.onWaits(waitsAt(asked), chatUrl: chatUrl(clientId), fromOnScreen: true);
    rows = <Map<String, String>>[
      <String, String>{'from': 'order', 'at': order},
    ];
    final int before = calls;
    replies.onWaits(waitsAt(order), chatUrl: chatUrl(clientId), fromOnScreen: false);
    await replies.look(forced: false);
    expect(calls, before + 1, reason: 'the page moved on: asked at once, not a minute later');
    expect(lastAfter, asked, reason: "after the customer's place, not the page's");
    expect(replies.unread.value, isFalse, reason: "an order's status is not a reply");
    expect(told, 0);

    // Then a person answered, and the page out of sight drew that too.
    rows.add(<String, String>{'from': 'human', 'at': reply});
    replies.onWaits(waitsAt(reply), chatUrl: chatUrl(clientId), fromOnScreen: false);
    await replies.look(forced: false);
    expect(calls, before + 2);
    expect(replies.unread.value, isTrue, reason: 'drawn where nobody saw it');
    expect(told, 1);
    final Map<String, Object?> wait =
        ((await stored(clientId))['waits']! as List<Object?>).single! as Map<String, Object?>;
    expect(wait['at'], asked, reason: "the customer's place");
    expect(wait['page'], reply, reason: "the page's own, kept for when the chat appears");

    // The same list again: the page did not move, so nothing is asked, and
    // its place is still not the customer's.
    replies.onWaits(waitsAt(reply), chatUrl: chatUrl(clientId), fromOnScreen: false);
    await replies.look(forced: false);
    expect(calls, before + 2);
    expect(told, 1, reason: 'told once per reply');
    expect(replies.unread.value, isTrue, reason: 'a chat out of sight does not make it seen');

    // A chat still open under another bot must not overwrite this one's list.
    replies.onWaits(<Object>[], chatUrl: chatUrl('kb_live_ffffffffffffffff'), fromOnScreen: true);
    await pumpEventQueue();
    expect(replies.unread.value, isTrue, reason: "another bot's list is not this one's");

    // The tab is selected: what the page drew is in front of the customer.
    replies.chatAppeared();
    await pumpEventQueue();
    expect(replies.unread.value, isFalse);
    replies.chatWentAway();
    await pumpEventQueue();
    expect(replies.unread.value, isFalse, reason: 'appearing caught up with the page');
    final Map<String, Object?> seen =
        ((await stored(clientId))['waits']! as List<Object?>).single! as Map<String, Object?>;
    expect(seen['at'], reply);
    replies.onReply = null;
  });

  test('a saved reply: unread at start; a chat appearing clears it at once, not after a slow look', () async {
    const String clientId = 'kb_live_abcdefabcdefabcdefabcdef';
    final KeydaReplies replies = KeydaReplies.instance;
    final int now = DateTime.now().millisecondsSinceEpoch;
    // As saved before `page` existed: a reply told about, not yet shown.
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'keyda_bot_waits_$clientId',
      jsonEncode(<String, Object>{
        'root': chatUrl(clientId).toString(),
        'waits': <Object>[
          <String, Object>{'c': chat, 'at': asked, 't': now, 'told': reply},
        ],
      }),
    );
    rows = <Map<String, String>>[];
    delay = const Duration(milliseconds: 400);
    final int before = calls;
    replies.start(chatUrl(clientId), clientId);
    await pumpEventQueue();
    expect(replies.unread.value, isTrue, reason: 'loaded from disk');

    // The start's look is waiting on the network.
    replies.chatAppeared();
    await Future<void>.delayed(Duration.zero);
    expect(replies.unread.value, isFalse, reason: 'off at once, not behind the look');

    // A chat that failed to load did not show it: unread again.
    replies.chatWentAway();
    await replies.look(forced: false);
    expect(calls, before + 1);
    expect(replies.unread.value, isTrue);
    delay = Duration.zero;
  });
}
