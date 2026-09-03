# Keyda Bot for WordPress

This plugin is a thin wrapper around a hosted chat page. It renders no chat UI
of its own: it enqueues one script, `widget.js`, served by Keyda, with your
client id attached to it, and that script draws the chat inside a shadow root
on your visitor's page. Nothing else.

That is deliberate, and it is the same decision every SDK in this repo makes
(see [CONTRACT.md](../CONTRACT.md)). There is exactly one chat interface. An
owner who changes their welcome message or their accent colour in the Keyda
Business dashboard expects it live on their site immediately — which is only
true if the site is loading the one renderer rather than a copy of it frozen
into a plugin release. It also means a fix ships once instead of seven times.

The trade you are making by installing it: the chat is a hosted page, so it is
not offline-capable, and your visitors' questions are answered by Keyda's API.
If that is not acceptable for your site, this plugin is the wrong tool and no
setting in it will change that.

Unlike the Android and iOS packages here, there is no WebView involved — the
browser is already the browser. The WebView-specific rules in the contract
(external links, keyboard insets, safe areas) are the operating system's job on
this platform, not ours.

That is also why this package loads `{baseUrl}/widget.js` instead of the
contract's `{baseUrl}/chat/{clientId}`: the hosted chat page is itself a wrapper
that loads `widget.js` with the same `data-key`, so both routes end at the one
renderer, and a browser does not need the page in the middle.

## What is in here

```
keyda-bot/
  keyda-bot.php          plugin header, front-end enqueue, the data-key tag filter
  includes/settings.php  Settings -> Keyda Bot, one validated field
  readme.txt             WordPress.org listing (this file is not the listing)
  uninstall.php          deletes the one option when the plugin is deleted
```

No build step, no `composer install`, no `npm install`. The directory you see
is the directory that ships. PHP 7.4+, WordPress 5.6+, zero dependencies.

## Installing on a site

Any of these; the plugin folder must end up named `keyda-bot`.

**From a zip.** Plugins → Add New → Upload Plugin → the built zip → Activate.

**By hand.** Copy the `keyda-bot/` directory into `wp-content/plugins/`, then
activate it from the Plugins screen.

**WP-CLI.** `wp plugin install` takes a zip or a slug, not a directory, so
either build the zip first (below) or copy the folder and activate it:

```sh
cp -R keyda-bot /path/to/wp-content/plugins/
wp plugin activate keyda-bot
```

Then: **Settings → Keyda Bot**, paste the client id from the Install page of
your dashboard at <https://keyda.in/business/app/>, save, and open the site in
a new tab. An id must match `kb_live_` followed by 8–48 hex characters; anything
else is rejected inline and never overwrites the id already saved, so a typo
cannot take a live bot off a live site.

With the field empty the plugin adds nothing to the page at all — a site with no
key is byte-for-byte the site it was before activation.

## Pointing it at another host

The default is `https://keyda.in/business`. Staging and self-hosted installs
override it, either in `wp-config.php`:

```php
define( 'KEYDA_BOT_BASE_URL', 'https://chat.example.com' );
```

or from a theme or mu-plugin:

```php
add_filter( 'keyda_bot_base_url', function () {
	return 'https://chat.example.com';
} );
```

`widget.js` derives its API endpoint from its own `<script src>`, so this moves
the script and its requests together. An override that is not a valid http(s)
URL is ignored and the default is used, because a malformed one becomes a script
tag pointing at nothing and fails silently in every browser.

Give the override a scheme and a host only — `https://chat.example.com`, never
`https://example.com/keyda`. The widget builds its API base from the **origin**
of its own `src`, so a subdirectory is kept in the script URL and dropped from
the API URL. That combination is accepted here and loads a widget that cannot
reach its own API, which is the one shape of override this function cannot
recognise as wrong.

There is deliberately no admin field for this. It is an environment decision,
not a content decision, and putting it on the settings screen invites someone to
type a host into the box that answers their support ticket.

## Smoke test before you ship a change

1. Activate with no id set → no `widget.js` anywhere in the page source, and a
   notice on the Plugins screen saying so.
2. Save `not-a-key` → inline error under the field, previous value intact.
3. Save a real id → the footer carries one tag for handle `keyda-bot` with both
   `data-key="kb_live_…"` and `async` on it, and the launcher appears. The rest
   of the tag varies with the site: a theme without HTML5 script support also
   gets `type='text/javascript'`, and WordPress before 6.3 quotes its own
   attributes with single quotes.
   If you attach a `wp_add_inline_script()` to the handle, check `data-key`
   landed on the tag carrying `src`, not on the inline block beside it.
4. `wp option get keyda_bot_client_id` returns it; delete the plugin from the
   Plugins screen and the same command returns nothing.
5. Lint every file: `find keyda-bot -name '*.php' -exec php -l {} \;`

If you have the WordPress coding standards installed globally,
`phpcs --standard=WordPress keyda-bot` is worth a pass before a release; it is
not required to work on the plugin and nothing here depends on it.

## Releasing

Version numbers live in exactly two places and must match:

* `Version:` in `keyda-bot/keyda-bot.php`
* `Stable tag:` in `keyda-bot/readme.txt`

Steps:

1. Bump both, and add the release to the `== Changelog ==` and
   `== Upgrade Notice ==` sections of `readme.txt`.
2. Set `Tested up to:` in `readme.txt` to the WordPress version you actually
   ran the smoke test on. Bump it because you tested, not because time passed —
   the field is a claim, and a stale one is the first thing reviewers check.
3. Build the zip **outside the repo** so the artifact is not left untracked in
   a working copy:

   ```sh
   cd wordpress
   zip -r /tmp/keyda-bot-0.1.4.zip keyda-bot -x '*.DS_Store' -x '__MACOSX/*'
   ```

   Unzip it somewhere clean and confirm the top-level folder is `keyda-bot/`.
   WordPress names the install directory after it, and a wrong name installs a
   second copy alongside the old one.
4. Publish to WordPress.org (slug `keyda-bot`, assigned at approval):

   ```sh
   svn co https://plugins.svn.wordpress.org/keyda-bot keyda-bot-svn
   rsync -a --delete --exclude '.DS_Store' keyda-bot/ keyda-bot-svn/trunk/
   cd keyda-bot-svn
   svn add --force trunk
   svn cp trunk "tags/0.1.4"
   svn ci -m "Release 0.1.4"
   ```

   WordPress.org serves whichever tag `Stable tag:` in **trunk's** `readme.txt`
   names. Committing the tag without that line updated ships nothing.
5. Listing images are not part of the plugin. They go in the SVN `assets/`
   directory at the repository root — `icon-256x256.png`,
   `banner-772x250.png`, and `screenshot-1.png` onwards. `readme.txt` has no
   `== Screenshots ==` section today because there are no screenshot files; add
   the section in the same commit as the files, not before.

MIT licensed, like the rest of this repo — MIT is GPL-compatible, which is what
the WordPress.org guidelines require.
