<?php
/**
 * Plugin Name:       Keyda Bot
 * Plugin URI:        https://business.keyda.in/
 * Description:       Adds your Keyda Bot chat assistant to your site. Paste your client id under Settings &rarr; Keyda Bot; the greeting, colours and answers all come from your Keyda Business dashboard.
 * Version:           0.1.0
 * Requires at least: 5.6
 * Requires PHP:      7.4
 * Author:            Keyda
 * Author URI:        https://keyda.in/
 * License:           MIT
 * License URI:       https://opensource.org/licenses/MIT
 * Text Domain:       keyda-bot
 * Domain Path:       /languages
 *
 * This plugin renders no chat UI of its own. It puts one hosted script on the
 * front end and gets out of the way. Everything a visitor sees is drawn by
 * widget.js inside a shadow root, so an owner who changes their welcome
 * message in the dashboard does not wait for a plugin update to see it live.
 *
 * @package Keyda_Bot
 */

// Loading this file outside WordPress would run it with none of the functions
// below defined; refuse rather than emit a stack of fatals into the response.
defined( 'ABSPATH' ) || exit;

/**
 * The one option this plugin owns. Duplicated verbatim in uninstall.php, which
 * runs without the plugin loaded and so cannot read this constant.
 */
define( 'KEYDA_BOT_OPTION', 'keyda_bot_client_id' );

/** Script handle. Other plugins dequeue by handle, so it must stay stable. */
define( 'KEYDA_BOT_HANDLE', 'keyda-bot' );

/** Where the widget is served from unless the site overrides it. */
define( 'KEYDA_BOT_DEFAULT_BASE_URL', 'https://business.keyda.in' );

/**
 * Is this string a client id we would be willing to put on a live page?
 *
 * Shape is `kb_live_` plus 8 to 48 hexadecimal characters. Anything else is a
 * typo or a half-pasted key, and loading it would show a visitor a chat that
 * can never answer.
 *
 * @param string $client_id Candidate id.
 * @return bool
 */
function keyda_bot_is_valid_client_id( $client_id ) {
	// \z, not $: in PCRE, $ also matches just before a trailing newline, so
	// "kb_live_abc12345\n" would pass here and go straight into a data-key
	// attribute. \z is end-of-subject and nothing else, which is what the
	// same pattern means in the JavaScript and Kotlin SDKs.
	return 1 === preg_match( '/^kb_live_[0-9a-f]{8,48}\z/', (string) $client_id );
}

/**
 * The configured client id, or an empty string when there is not a usable one.
 *
 * The value is validated on save, but any plugin can call update_option() and
 * put anything it likes in the row. Re-checking here is what keeps a broken
 * value from reaching a visitor's page.
 *
 * @return string
 */
function keyda_bot_client_id() {
	$client_id = trim( (string) get_option( KEYDA_BOT_OPTION, '' ) );

	return keyda_bot_is_valid_client_id( $client_id ) ? $client_id : '';
}

/**
 * Base URL the widget is loaded from, without a trailing slash.
 *
 * Overridable two ways because the two audiences differ: a staging site sets
 * the constant in wp-config.php where the rest of its environment already
 * lives, and a self-hosted install filters it from a theme or mu-plugin.
 *
 * widget.js derives its API endpoint from its own <script src>, so changing
 * this points both the script and its requests at the same host.
 *
 * @return string
 */
function keyda_bot_base_url() {
	$base = KEYDA_BOT_DEFAULT_BASE_URL;

	if ( defined( 'KEYDA_BOT_BASE_URL' ) && is_string( KEYDA_BOT_BASE_URL ) ) {
		$base = KEYDA_BOT_BASE_URL;
	}

	/**
	 * Filters the host the Keyda Bot widget is loaded from.
	 *
	 * @param string $base Base URL, no trailing slash. Default https://business.keyda.in.
	 */
	$base = (string) apply_filters( 'keyda_bot_base_url', $base );
	$base = untrailingslashit( trim( $base ) );

	$scheme = wp_parse_url( $base, PHP_URL_SCHEME );
	$host   = wp_parse_url( $base, PHP_URL_HOST );

	// A malformed override would otherwise become a <script src> pointing at
	// nothing, which fails silently in every browser. Fall back instead.
	if ( empty( $host ) || ! in_array( $scheme, array( 'http', 'https' ), true ) ) {
		return KEYDA_BOT_DEFAULT_BASE_URL;
	}

	return $base;
}

/**
 * Queue the widget on the front end.
 *
 * Why wp_enqueue_script and not an echoed <script> tag in wp_head:
 * a raw echo is invisible to everything else that reasons about scripts on
 * this site. Caching and "optimise JavaScript" plugins work from the enqueue
 * registry, so an unregistered tag is one they cannot exclude from
 * concatenation or minification; without a handle nobody can dequeue us on a
 * page where we do not belong; and defer/async handling, the loading strategy
 * WordPress core added in 6.3, only applies to registered scripts. That
 * matters more here than for most scripts: widget.js reads its own tag to
 * find the key (document.currentScript, falling back to
 * script[src*="widget.js"][data-key]), so a layer that rewrites or merges an
 * anonymous tag carries the key off with it and the bot never loads, with
 * nothing in the console to say why.
 *
 * @return void
 */
function keyda_bot_enqueue_widget() {
	if ( '' === keyda_bot_client_id() ) {
		// Not configured: add nothing at all to the page. A site with no key
		// should be byte-for-byte the site it was before activation.
		return;
	}

	wp_enqueue_script(
		KEYDA_BOT_HANDLE,
		keyda_bot_base_url() . '/widget.js',
		array(),
		// null, not false: false makes WordPress append its own ?ver=, which
		// busts the CDN cache of a file we do not version from here.
		null,
		true
	);
}
add_action( 'wp_enqueue_scripts', 'keyda_bot_enqueue_widget' );

/**
 * Attach data-key to our tag, and async unless something else already chose.
 *
 * The attribute cannot go in the src: widget.js reads data-key off the element
 * it is running from, and that is also how a second embed on the same page is
 * detected. wp_script_add_data() only understands the keys core defines
 * (conditional, group, strategy), so arbitrary attributes go through this
 * filter, which is the supported route and leaves the script registered.
 *
 * @param string $tag    The full <script> tag WordPress built.
 * @param string $handle Handle of the script being output.
 * @return string
 */
function keyda_bot_script_loader_tag( $tag, $handle ) {
	if ( KEYDA_BOT_HANDLE !== $handle ) {
		return $tag;
	}

	$client_id = keyda_bot_client_id();
	if ( '' === $client_id ) {
		return $tag;
	}

	// Find OUR element, not merely the first '<script' in the string. The
	// moment anything calls wp_add_inline_script() on this handle, WordPress
	// hands this filter both elements at once — <script id="keyda-bot-js-before">
	// and then ours — and the inline one comes first. data-key on that one
	// leaves the real tag keyless: widget.js reads nothing from
	// document.currentScript, its script[src*="widget.js"][data-key] fallback
	// finds nothing either, and the bot never loads, with one console warning
	// as the only trace.
	//
	// The lookahead cannot cross '>', so it only matches inside one opening
	// tag, and requiring the closing quote immediately after the id keeps the
	// -before/-after ids — which have this one as a prefix — out of it.
	$pattern = '/<script(?=[^>]*\bid=([\'"])' . preg_quote( KEYDA_BOT_HANDLE, '/' ) . '-js\1)/';
	$open    = false;

	if ( preg_match( $pattern, $tag, $match, PREG_OFFSET_CAPTURE ) ) {
		$open = $match[0][1];
	} elseif ( 1 === substr_count( $tag, '<script' ) ) {
		// Some "tidy up the markup" plugins strip script ids. With exactly one
		// element in the string there is nothing to confuse ours with.
		$open = strpos( $tag, '<script' );
	}

	if ( false === $open ) {
		// Another filter replaced the markup with something we do not
		// recognise. Handing back its own string is safer than guessing.
		return $tag;
	}

	// Read async/defer off OUR opening tag only. Asked of the whole string,
	// the question can be answered by an inline block that merely contains
	// the word, and we would drop an attribute nothing had actually set.
	$end     = strpos( $tag, '>', $open );
	$our_tag = false === $end ? substr( $tag, $open ) : substr( $tag, $open, $end - $open + 1 );

	$attributes = ' data-key="' . esc_attr( $client_id ) . '"';

	// Only volunteer async. If a performance plugin has already deferred this
	// tag, adding async on top of it changes execution order behind its back.
	if ( false === strpos( $our_tag, ' async' ) && false === strpos( $our_tag, ' defer' ) ) {
		$attributes .= ' async';
	}

	return substr_replace( $tag, '<script' . $attributes, $open, strlen( '<script' ) );
}
add_filter( 'script_loader_tag', 'keyda_bot_script_loader_tag', 10, 2 );

/**
 * Add a Settings link to this plugin's row on the Plugins screen.
 *
 * @param array $links Existing action links.
 * @return array
 */
function keyda_bot_plugin_action_links( $links ) {
	$settings = sprintf(
		'<a href="%s">%s</a>',
		esc_url( admin_url( 'options-general.php?page=keyda-bot' ) ),
		esc_html__( 'Settings', 'keyda-bot' )
	);

	array_unshift( $links, $settings );

	return $links;
}
add_filter( 'plugin_action_links_' . plugin_basename( __FILE__ ), 'keyda_bot_plugin_action_links' );

/**
 * Say plainly, on the Plugins screen only, when the plugin is doing nothing.
 *
 * An activated plugin with no key looks installed and is not running. Telling
 * the owner belongs here rather than on every admin page, and never in front
 * of a visitor: a site's customers are not the people who can fix this.
 *
 * @return void
 */
function keyda_bot_admin_notice_unconfigured() {
	if ( ! current_user_can( 'manage_options' ) ) {
		return;
	}

	$screen = function_exists( 'get_current_screen' ) ? get_current_screen() : null;
	if ( ! $screen || 'plugins' !== $screen->id ) {
		return;
	}

	if ( '' !== keyda_bot_client_id() ) {
		return;
	}

	printf(
		'<div class="notice notice-warning"><p>%s</p></div>',
		sprintf(
			/* translators: %s: link to the plugin settings page. */
			esc_html__( 'Keyda Bot has no client id yet, so nothing is added to your site. %s', 'keyda-bot' ),
			sprintf(
				'<a href="%s">%s</a>',
				esc_url( admin_url( 'options-general.php?page=keyda-bot' ) ),
				esc_html__( 'Add your client id', 'keyda-bot' )
			)
		)
	);
}
add_action( 'admin_notices', 'keyda_bot_admin_notice_unconfigured' );

// The settings screen is admin-only code. Loading it on every front-end
// request would parse a file that can never run there, on every page view.
if ( is_admin() ) {
	require_once plugin_dir_path( __FILE__ ) . 'includes/settings.php';
}

/*
 * No load_plugin_textdomain() call on purpose: since WordPress 4.6, translations
 * for plugins hosted on WordPress.org load automatically from the Text Domain in
 * the header above, and calling it again only adds a filesystem lookup.
 */
