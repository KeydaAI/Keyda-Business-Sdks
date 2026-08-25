/// Configuration parsing for the Keyda Business chat.
///
/// Deliberately free of any `dart:ui` or Flutter import: every rule that
/// decides which URL a customer is shown lives here, so it can be tested on
/// the Dart VM without a device in the loop.
library;

/// Where the hosted chat lives unless the integrator says otherwise.
const String kKeydaDefaultBaseUrl = 'https://keyda.in/business';

/// `kb_live_` followed by 8-48 lowercase hex characters.
///
/// Anchored at both ends, and Dart's `$` (ECMAScript semantics, no multiline)
/// will not forgive a trailing newline — a client id pasted out of a terminal
/// with a stray newline is a different string and must be reported as one.
final RegExp _clientIdPattern = RegExp(r'^kb_live_[0-9a-f]{8,48}$');

/// Thrown at `KeydaBot.init` when the client id or base URL cannot possibly
/// address a chat.
///
/// This fires during integration, on the developer's machine, on the first
/// run — which is the only time it is cheap to fix. The alternative is a
/// customer tapping the chat button and getting a 404 page.
class KeydaBotConfigError extends ArgumentError {
  /// Creates the error with a message aimed at whoever wired up the SDK.
  KeydaBotConfigError(super.message);

  @override
  String toString() => 'KeydaBotConfigError: $message';
}

/// Whether [clientId] has the shape the platform issues.
///
/// Shape only. It says nothing about whether the id exists or is enabled —
/// only the server knows that.
bool isValidClientId(String clientId) => _clientIdPattern.hasMatch(clientId);

/// Returns [clientId] unchanged, or throws [KeydaBotConfigError].
///
/// Nothing is trimmed or lower-cased on the way through. Quietly repairing an
/// id here would mean the same string that works on Flutter fails on iOS and
/// Android, and the integrator would have to discover that per platform.
String validateClientId(String clientId) {
  if (isValidClientId(clientId)) {
    return clientId;
  }
  throw KeydaBotConfigError(
    'Not a Keyda client id: "$clientId". Expected kb_live_ followed by 8-48 '
    'lowercase hex characters, exactly as shown under Install in the Keyda '
    'Business dashboard (watch for a copied space, newline or capital letter).',
  );
}

/// Parses [baseUrl] into an origin the chat can be loaded from.
///
/// Throws [KeydaBotConfigError] for anything that cannot host a page: a bare
/// host with no scheme, a scheme no WebView will load, an empty host, or a
/// URL carrying a query or fragment (those would be dropped when the chat
/// path is appended, so accepting them would silently ignore what was asked).
Uri normalizeBaseUrl(String baseUrl) {
  final Uri? parsed = Uri.tryParse(baseUrl.trim());
  if (parsed == null) {
    throw KeydaBotConfigError('baseUrl is not a URL: "$baseUrl".');
  }
  if (parsed.scheme != 'https' && parsed.scheme != 'http') {
    throw KeydaBotConfigError(
      'baseUrl must start with https:// (http:// is allowed for local and '
      'staging servers only). Got: "$baseUrl".',
    );
  }
  if (parsed.host.isEmpty) {
    throw KeydaBotConfigError('baseUrl has no host: "$baseUrl".');
  }
  if (parsed.hasQuery || parsed.hasFragment) {
    throw KeydaBotConfigError(
      'baseUrl must be an origin, optionally with a path prefix — no query '
      'string and no #fragment. Got: "$baseUrl".',
    );
  }
  return parsed;
}

/// Builds `{baseUrl}/chat/{clientId}`, validating both halves first.
///
/// A path prefix in [baseUrl] is kept, so a self-hosted install mounted at
/// `https://acme.example/support` still resolves to
/// `https://acme.example/support/chat/kb_live_...`.
Uri buildChatUrl({
  required String clientId,
  String baseUrl = kKeydaDefaultBaseUrl,
}) {
  final String id = validateClientId(clientId);
  final Uri base = normalizeBaseUrl(baseUrl);
  final List<String> segments = <String>[
    // Empty segments come from a trailing slash or a doubled one; leaving them
    // in would produce `//chat/` and a 404 on strict servers.
    ...base.pathSegments.where((String segment) => segment.isNotEmpty),
    'chat',
    id,
  ];
  return Uri(
    scheme: base.scheme,
    userInfo: base.userInfo,
    host: base.host,
    port: base.hasPort ? base.port : null,
    pathSegments: segments,
  );
}

/// Whether [candidate] is still the chat page itself.
///
/// Compared by PATH, not merely by origin, and the reason is specific. The
/// chat page carries a real "Powered by Keyda" link, and the widget builds it
/// from its own script origin:
///
///     a.href = apiBase.replace('/api/business/v1', '') + '/business/';
///
/// which on the default deployment is `https://keyda.in/business/` —
/// the SAME origin as `https://keyda.in/business/chat/{clientId}`. An origin
/// comparison therefore answers "yes, that is ours", the WebView navigates in
/// place, and the customer's conversation is replaced by a marketing site with
/// no route back. It does not recover: the widget re-greets on mount and
/// persists nothing but a session id, so every message on screen is gone.
///
/// A query or a #fragment on the chat page is still the chat page. Anything
/// else on that host is not.
bool staysInChat(Uri candidate, Uri chatUrl) {
  if (candidate.scheme.isEmpty || candidate.host.isEmpty) {
    return false;
  }
  if (candidate.scheme.toLowerCase() != chatUrl.scheme.toLowerCase() ||
      candidate.host.toLowerCase() != chatUrl.host.toLowerCase() ||
      candidate.port != chatUrl.port) {
    return false;
  }
  final String here = candidate.path;
  final String chat = chatUrl.path;
  return here == chat || here.startsWith('$chat/');
}

/// Schemes the WebView uses to talk to itself rather than to open anything a
/// person could read.
///
/// `about:blank` in particular is loaded internally during teardown and on
/// some `target="_blank"` paths; handing it to a link handler would flash a
/// blank browser tab at the customer for no reason.
bool isInternalScheme(String scheme) {
  const Set<String> internal = <String>{'about', 'blob', 'data', 'javascript'};
  return internal.contains(scheme.toLowerCase());
}
