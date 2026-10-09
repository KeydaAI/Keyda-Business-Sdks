import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A reply from the business that arrives while the chat is closed.
///
/// A customer who asked for a person leaves their details and closes the chat;
/// the owner answers in the dashboard an hour later. The answer lands in the
/// conversation, and the chat page shows it the next time it opens — but
/// nothing told the customer to open it. This is that something.
///
/// The page is the source of truth. It keeps the chats it is waiting on (up to
/// three, for 14 days, each with the time of the last row it showed) and sends
/// that list over the bridge as `keyda:waits` whenever it changes. This keeps a
/// copy (shared_preferences), and when the app comes to the foreground with no
/// chat on screen it asks the same public route the page asks
/// (`/widget/{clientId}/messages`) whether a person has written since. Nothing
/// here moves the page's place: the page does that when it draws the reply,
/// and sends the list back. Only a chat on screen counts as the customer having
/// seen it — one loaded out of sight draws the reply all the same.
class KeydaReplies with WidgetsBindingObserver {
  KeydaReplies._();

  /// The one watcher; `KeydaBot` and every chat talk to it.
  static final KeydaReplies instance = KeydaReplies._();

  static const int _maxWaits = 3;
  static const Duration _ttl = Duration(days: 14);

  /// One look per minute at most. Three requests a foreground is nothing;
  /// three a second is.
  static const Duration _minInterval = Duration(minutes: 1);

  /// What `checkForReplies()` still waits between looks, for a host that
  /// calls it a lot.
  static const Duration _minForcedInterval = Duration(seconds: 10);

  /// A page of 100 rows is far below this; anything bigger is not the route
  /// we know.
  static const int _maxBodyBytes = 1 << 20;
  static const Duration _timeout = Duration(seconds: 10);

  static final RegExp _conversation = RegExp(r'^[0-9a-fA-F-]{36}$');

  /// The server's ISO time, as the page stores it. Compared as strings, as
  /// the page does.
  static final RegExp _time = RegExp(r'^[0-9T:.+\-Z]{0,40}$');

  /// True while a person's reply is waiting to be read.
  final ValueNotifier<bool> unread = ValueNotifier<bool>(false);

  /// Called once per new reply, while no chat is on screen.
  VoidCallback? onReply;

  Uri? _messages;
  String? _root;
  String? _key;
  List<_Wait> _waits = <_Wait>[];
  DateTime _lastLook = DateTime.fromMillisecondsSinceEpoch(0);
  bool _observing = false;
  int _onScreen = 0;

  /// Every change to the list runs after the one before it: a page update
  /// that lands while a look is waiting on the network must not be undone
  /// by the look's result.
  Future<void> _queue = Future<void>.value();

  Future<void> _run(Future<void> Function() work) {
    final Future<void> next = _queue.then((_) => work()).catchError((Object e) {
      debugPrint('KeydaBot: reply check: $e');
    });
    _queue = next;
    return next;
  }

  /// From `KeydaBot.init`. Safe to call again; a different client id or
  /// server starts afresh.
  void start(Uri chatUrl, String clientId) {
    final Uri messages = Uri(
      scheme: chatUrl.scheme,
      host: chatUrl.host,
      port: chatUrl.hasPort ? chatUrl.port : null,
      path: '/api/business/v1/widget/$clientId/messages',
    );
    final String root = chatUrl.toString();
    final String key = 'keyda_bot_waits_$clientId';
    _run(() async {
      _messages = messages;
      if (_key != key || _root != root) {
        _key = key;
        _root = root;
        // Another bot's first look owes nothing to the last one's minute.
        _lastLook = DateTime.fromMillisecondsSinceEpoch(0);
        await _load();
      }
    });
    if (!_observing) {
      _observing = true;
      WidgetsFlutterBinding.ensureInitialized().addObserver(this);
    }
    look(forced: false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) look(forced: false);
  }

  /// A `keyda:waits` message from the page of the chat at [chatUrl], which
  /// [fromOnScreen] says counts as on screen.
  ///
  /// Only a chat on screen moves the customer's place. One loaded out of
  /// sight — a tab not selected, kept alive — keeps polling and draws what
  /// comes where nobody sees it; taking its word made the badge go out on a
  /// reply never seen. Nor is its word that a person wrote: the page moves
  /// its place for any row — an order's status, the bot. When it moves on,
  /// this asks the route at once instead, which counts only a person's rows,
  /// so a reply turns on the badge and calls [onReply], and anything else
  /// changes nothing.
  void onWaits(Object? list, {required Uri chatUrl, required bool fromOnScreen}) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<_Wait> parsed = <_Wait>[];
    if (list is List) {
      for (final Object? item in list.take(_maxWaits)) {
        if (item is! Map) continue;
        final Object? c = item['c'];
        final Object? at = item['at'];
        final Object? t = item['t'];
        if (c is! String || !_conversation.hasMatch(c)) continue;
        if (at is! String || !_time.hasMatch(at)) continue;
        if (t is! num || t <= 0 || now - t >= _ttl.inMilliseconds) continue;
        parsed.add(_Wait(c, at, at, t.toInt(), at));
      }
    }
    final String root = chatUrl.toString();
    _run(() async {
      // This watcher follows the last KeydaBot.init(); a chat still open under
      // an earlier client id or server must not overwrite that one's list.
      if (root != _root) return;
      final Map<String, _Wait> prior = <String, _Wait>{
        for (final _Wait w in _waits) w.c: w,
      };
      bool moved = false;
      for (final _Wait w in parsed) {
        final _Wait? p = prior[w.c];
        if (p == null) continue;
        if (!fromOnScreen) {
          if (w.page.compareTo(p.page) > 0) moved = true;
          w.at = _earlier(p.at, w.page);
        }
        // What the customer was already told about survives the page's update.
        w.told = _later(p.told, w.at);
      }
      _waits = parsed;
      await _settle();
      // Not held to once a minute: the page's own poll, every 12 seconds, is
      // what bounds it.
      if (moved) await _lookNow(Duration.zero);
    });
  }

  /// A chat came on screen: whatever is waiting is about to be shown there,
  /// and whatever a chat out of sight drew is in front of the customer now.
  ///
  /// Unread goes off at once rather than behind the queue, where a look can
  /// be waiting on a slow network for tens of seconds — but in a microtask,
  /// never from here: this is called from a chat page's initState, inside a
  /// build, and a listener that rebuilds (a ValueListenableBuilder badge on
  /// the screen under the chat) cannot be marked for a rebuild from inside
  /// someone else's build — it kept its old value, and the badge stayed on
  /// after the chat had shown the reply.
  void chatAppeared() {
    _onScreen++;
    scheduleMicrotask(() {
      if (_onScreen > 0) unread.value = false;
    });
    _run(() async {
      for (final _Wait w in _waits) {
        w.at = _later(w.at, w.page);
      }
      await _settle();
    });
  }

  /// Unread again only if the chat did not get to show the reply (it failed
  /// to load, say): the page moves its place when it draws one, and sends the
  /// list back first.
  void chatWentAway() {
    if (_onScreen > 0) _onScreen--;
    _run(_settle);
  }

  /// `KeydaBot.checkForReplies()`, and the foreground.
  Future<void> look({required bool forced}) {
    if (_onScreen > 0) return Future<void>.value();
    return _run(() => _lookNow(forced ? _minForcedInterval : _minInterval));
  }

  /// Unread: a person wrote past the customer's place, and no chat is on
  /// screen to show it.
  Future<void> _settle() async {
    unread.value =
        _onScreen == 0 && _waits.any((_Wait w) => w.told.compareTo(w.at) > 0);
    await _save();
  }

  /// Asks the route, unless the last look was under [limit] ago.
  Future<void> _lookNow(Duration limit) async {
    final Uri? messages = _messages;
    if (messages == null) return;
    final DateTime now = DateTime.now();
    final int before = _waits.length;
    _waits.removeWhere(
        (_Wait w) => now.millisecondsSinceEpoch - w.t >= _ttl.inMilliseconds);
    if (_waits.length != before) await _settle();
    if (_waits.isEmpty || _onScreen > 0) return;
    if (limit > Duration.zero && now.difference(_lastLook) < limit) {
      return;
    }
    _lastLook = now;

    // Offline is not "no reply": a failed look changes nothing, so a badge
    // the customer has not acted on stays until the page shows them the reply.
    bool fresh = false;
    for (final _Wait w in List<_Wait>.of(_waits)) {
      final List<Object?>? rows = await _fetch(messages, w);
      if (rows == null) continue;
      String latest = '';
      for (final Object? row in rows) {
        if (row is! Map || row['from'] != 'human') continue;
        final Object? at = row['at'];
        if (at is String && at.compareTo(w.at) > 0 && at.compareTo(latest) > 0) {
          latest = at;
        }
      }
      if (latest.compareTo(w.told) > 0) {
        w.told = latest;
        fresh = true;
      }
    }
    await _settle();
    // The customer opened the chat while we were asking: they are reading it.
    if (fresh && _onScreen == 0 && unread.value) onReply?.call();
  }

  Future<List<Object?>?> _fetch(Uri messages, _Wait w) async {
    final HttpClient client = HttpClient()..connectionTimeout = _timeout;
    try {
      final Uri url = messages.replace(queryParameters: <String, String>{
        'conversationId': w.c,
        if (w.at.isNotEmpty) 'after': w.at,
      });
      final HttpClientRequest request = await client.getUrl(url).timeout(_timeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final HttpClientResponse response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) return null;
      final BytesBuilder body = BytesBuilder(copy: false);
      await for (final List<int> chunk in response.timeout(_timeout)) {
        body.add(chunk);
        if (body.length > _maxBodyBytes) return null;
      }
      final Object? json = jsonDecode(utf8.decode(body.takeBytes()));
      if (json is! Map) return null;
      final Object? rows = json['messages'];
      return rows is List ? rows : <Object?>[];
    } catch (_) {
      // No network, a captive portal, a server hiccup: the next foreground
      // asks again.
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _load() async {
    _waits = <_Wait>[];
    unread.value = false;
    final String? key = _key;
    if (key == null) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(key);
      if (raw == null) return;
      final Object? json = jsonDecode(raw);
      if (json is! Map || json['root'] != _root) return;
      final Object? list = json['waits'];
      if (list is! List) return;
      for (final Object? item in list.take(_maxWaits)) {
        if (item is! Map) continue;
        final Object? c = item['c'];
        final Object? at = item['at'];
        final Object? t = item['t'];
        final Object? page = item['page'];
        final Object? told = item['told'];
        if (c is! String || !_conversation.hasMatch(c)) continue;
        if (at is! String || !_time.hasMatch(at)) continue;
        if (told is! String || !_time.hasMatch(told)) continue;
        if (t is! num) continue;
        // One saved before `page` existed is at its own place.
        final String p =
            page is String && _time.hasMatch(page) ? _later(page, at) : at;
        _waits.add(_Wait(c, at, p, t.toInt(), _later(told, p)));
      }
      unread.value =
          _onScreen == 0 && _waits.any((_Wait w) => w.told.compareTo(w.at) > 0);
    } catch (e) {
      debugPrint('KeydaBot: discarding an unreadable reply list: $e');
    }
  }

  Future<void> _save() async {
    final String? key = _key;
    if (key == null) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (_waits.isEmpty) {
        await prefs.remove(key);
        return;
      }
      await prefs.setString(
        key,
        jsonEncode(<String, Object?>{
          'root': _root,
          'waits': <Map<String, Object>>[
            for (final _Wait w in _waits)
              <String, Object>{
                'c': w.c,
                'at': w.at,
                'page': w.page,
                't': w.t,
                'told': w.told,
              },
          ],
        }),
      );
    } catch (e) {
      debugPrint('KeydaBot: could not save the reply list: $e');
    }
  }
}

String _later(String a, String b) => a.compareTo(b) > 0 ? a : b;
String _earlier(String a, String b) => a.compareTo(b) < 0 ? a : b;

/// One chat waiting for a reply.
class _Wait {
  _Wait(this.c, this.at, this.page, this.t, this.told);

  final String c;

  /// The customer's place: where the page was the last time a chat was on
  /// screen. The look asks for rows after it.
  String at;

  /// Where the page last said it was. A chat loaded out of sight keeps
  /// polling and draws the reply where nobody sees it, so its place is not
  /// the customer's.
  final String page;

  final int t;

  /// The newest reply the customer has been told about.
  String told;
}
