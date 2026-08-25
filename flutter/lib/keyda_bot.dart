/// Keyda Business chat for Flutter.
///
/// A thin wrapper that opens `{baseUrl}/chat/{clientId}` — the same hosted
/// chat page the web widget and every other Keyda SDK loads — in a WebView
/// over the host app.
library;

export 'src/chat_page.dart' show KeydaExternalLinkHandler;
export 'src/client_id.dart' show KeydaBotConfigError, kKeydaDefaultBaseUrl;
export 'src/keyda_bot.dart' show KeydaBot;
