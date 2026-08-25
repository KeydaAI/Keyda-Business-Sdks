=== Keyda Bot ===
Contributors: keyda
Tags: chatbot, live chat, customer support, ai, assistant
Requires at least: 5.6
Tested up to: 6.6
Requires PHP: 7.4
Stable tag: 0.1.0
License: MIT
License URI: https://opensource.org/licenses/MIT

Adds your Keyda Bot chat assistant to your site. One field: your client id. Everything else comes from your Keyda Business dashboard.

== Description ==

This plugin adds one hosted script to your site's front end, with your client
id attached to it. That script draws the chat — a launcher button in the corner
and a panel that opens when a visitor clicks it.

It is worth being plain about what that means, because it decides whether this
plugin suits you:

* The chat interface is served by Keyda, not rendered by this plugin. Your bot's
  greeting, accent colour, position, languages and answers are all set in your
  Keyda Business dashboard, and a change there is live on your site straight
  away — no plugin update, no cache to clear, no code to edit.
* Because there is one chat interface for every place a Keyda bot appears — your
  website, your Android app, your iOS app — a fix or an improvement reaches all
  of them at once.
* Your visitors' questions go to Keyda to be answered. That is what the bot is.
  See "External services" below for exactly what is sent.

The widget renders inside a shadow root, so your theme's CSS cannot break it and
its CSS cannot reach your site. It never throws an error into your page: if it
cannot reach Keyda while your page is loading it adds nothing at all and writes
one `[KeydaBot]` warning to the browser console, and a message that fails to
send is answered in the chat itself.

Your bot has to be set live in the dashboard. While it is still a draft the
launcher appears and tells visitors the chat is not available right now.

= What this plugin does not do =

* No offline mode. The bot is a hosted service; with no connection there is no
  answer.
* No push notifications.
* No third-party libraries, no tracking pixels, no device fingerprinting, no
  cookies, no visitor profile of any kind. The one thing that is reported is
  that the widget loaded, so your dashboard can tell you your bot is installed
  — described in full under "External services".
* No per-page targeting. The widget loads on every front-end page, which is the
  same behaviour as pasting the script tag into your footer.
* No theming beyond what your dashboard already controls.
* No PHP-side network calls. This plugin never contacts any server from your
  web host; only the visitor's browser talks to Keyda.

= External services =

This plugin loads a script from Keyda and the bot answers from Keyda's API, so
some data leaves the visitor's browser. Nothing leaves your server.

The script is loaded from `https://keyda.in/business/widget.js` (or from
whichever host you configure — see the FAQ). Once running, the visitor's browser
makes three kinds of request to that same host:

1. It fetches your bot's public settings — greeting, colour, launcher label —
   using your client id.
2. It records that your widget loaded, sending the path of the page it loaded
   on. This is the "your bot is live" confirmation on your dashboard, which
   keeps your site's domain and the time — not the path, and nothing about the
   visitor.
3. When a visitor sends a message, it posts that message and a conversation id.

The conversation id is stored in the visitor's browser (localStorage) so a
returning visitor keeps the same thread for 24 hours. It is not a cross-site
identifier and it is not read by this plugin.

Keyda's terms: https://keyda.in/terms-and-conditions
Keyda's privacy policy: https://keyda.in/privacy-policy

== Installation ==

1. Install and activate the plugin.
2. Go to **Settings &rarr; Keyda Bot**.
3. Paste the client id from the Install page of your Keyda Business dashboard.
   It looks like `kb_live_` followed by 8 to 48 characters from 0-9 and a-f.
4. Save, then open your site in a new tab. The chat button appears in the corner.

If the field is empty, the plugin adds nothing at all to your pages.

== Frequently Asked Questions ==

= Where do I find my client id? =

In the Keyda Business dashboard at https://keyda.in/business/app/, on the
Install page. Copy the id itself, not the whole script tag.

= It says my client id was not saved. =

The id must be `kb_live_` followed by 8 to 48 hexadecimal characters (0-9 and
a-f). The most common cause is pasting the entire `<script ...>` tag from the
dashboard instead of just the id. A rejected value never replaces the id you
already had saved, so a live bot stays live while you fix the typo.

= Can I point the plugin at a different host? =

Yes. Add this to `wp-config.php`:

`define( 'KEYDA_BOT_BASE_URL', 'https://chat.example.com' );`

or filter it from a theme or mu-plugin:

`add_filter( 'keyda_bot_base_url', function () { return 'https://chat.example.com'; } );`

The widget derives its API endpoint from the host it was loaded from, so this
moves both the script and its requests. An override that is not a valid http or
https URL is ignored and the default is used.

Give it a scheme and a host and nothing else — `https://chat.example.com`, not
`https://example.com/keyda`. The widget builds its API address from the *origin*
of its own script tag, so a subdirectory survives in the script URL and is
dropped from the API URL, which loads a widget that cannot reach anything.

= I installed it but no chat appears on my site. =

In this order:

1. **Settings &rarr; Keyda Bot**. With the field empty the plugin adds nothing.
2. Clear your caching plugin's cache. A page cached before you saved the id has
   no script tag in it.
3. Open your browser's developer console and look for a line beginning
   `[KeydaBot]`. "missing data-key" means something rewrote or merged the tag —
   exclude the handle `keyda-bot` from script concatenation.
4. If your bot has an authorised-domains list in the dashboard, your site's
   domain has to be on it. Until it is, the request is refused and the widget
   renders nothing.

= The chat button appears but says the chat is not available. =

Your bot is still a draft. Set it live in the Keyda Business dashboard; until
then that message is what your visitors get.

= Can I show the chat inside the page instead of as a floating button? =

Yes, and it needs nothing from this plugin. Put an empty container with a height
anywhere on a page, in a Custom HTML block:

`<div data-keyda-bot style="height:520px"></div>`

The widget fills that container instead of showing a launcher. That behaviour
belongs to the widget script itself, so it works wherever the widget loads.

= Does it work with WooCommerce? =

There is nothing extra to do. The widget loads on product, cart and checkout
pages like any other front-end page.

= Does it work with a caching plugin? =

The script is registered through WordPress's own enqueue system with the handle
`keyda-bot`, which is what caching and optimisation plugins read. If one of them
combines external scripts into a single file, exclude this handle: the widget
reads its own tag to find your client id, so a merged copy loses it.

= Does it slow my site down? =

The tag is async, so it never blocks your page. On load the widget makes two
small requests to Keyda — your bot's settings and the install ping described
above — and nothing more until a visitor sends a message.

= What happens when I delete the plugin? =

The single option holding your client id is removed. Nothing else is stored.

== Changelog ==

= 0.1.0 =
* First release.

== Upgrade Notice ==

= 0.1.0 =
First release.
