<?php
/**
 * Settings screen: Settings -> Keyda Bot.
 *
 * One field, one option. The rest of the bot's configuration — greeting,
 * accent colour, languages, what it knows — lives in the Keyda Business
 * dashboard, on purpose: a setting duplicated here would be a second place to
 * change it and a second place to be wrong.
 *
 * @package Keyda_Bot
 */

defined( 'ABSPATH' ) || exit;

/**
 * Slug of this screen, used for both the menu and the settings sections.
 */
define( 'KEYDA_BOT_PAGE', 'keyda-bot' );

/**
 * Option group. settings_fields() turns this into the nonce and the
 * option_page field that options.php validates on submit.
 */
define( 'KEYDA_BOT_OPTION_GROUP', 'keyda_bot_settings' );

/**
 * Slug our admin notices are filed under, kept apart from core's 'general' so
 * settings_errors() prints ours and core's "Settings saved." exactly once each.
 */
define( 'KEYDA_BOT_NOTICES', 'keyda_bot_messages' );

/**
 * Register the screen under Settings.
 *
 * @return void
 */
function keyda_bot_add_settings_page() {
	add_options_page(
		__( 'Keyda Bot', 'keyda-bot' ),
		__( 'Keyda Bot', 'keyda-bot' ),
		// Capability check number one: WordPress hides the menu entry and
		// refuses the screen for anyone without it.
		'manage_options',
		KEYDA_BOT_PAGE,
		'keyda_bot_render_settings_page'
	);
}
add_action( 'admin_menu', 'keyda_bot_add_settings_page' );

/**
 * Register the option, its sanitiser, and the single field.
 *
 * @return void
 */
function keyda_bot_register_settings() {
	register_setting(
		KEYDA_BOT_OPTION_GROUP,
		KEYDA_BOT_OPTION,
		array(
			'type'              => 'string',
			'sanitize_callback' => 'keyda_bot_sanitize_client_id',
			'default'           => '',
			// Nothing reads this over the REST API, and an option exposed
			// there is one more surface to reason about for no gain.
			'show_in_rest'      => false,
		)
	);

	add_settings_section(
		'keyda_bot_main',
		'',
		'keyda_bot_render_section_intro',
		KEYDA_BOT_PAGE
	);

	add_settings_field(
		KEYDA_BOT_OPTION,
		__( 'Client id', 'keyda-bot' ),
		'keyda_bot_render_client_id_field',
		KEYDA_BOT_PAGE,
		'keyda_bot_main',
		array( 'label_for' => KEYDA_BOT_OPTION )
	);
}
add_action( 'admin_init', 'keyda_bot_register_settings' );

/**
 * Validate the client id before it can be stored.
 *
 * By the time options.php calls this it has already checked the nonce from
 * settings_fields() and the capability behind the option group. That is not a
 * reason to trust the value: this function is public and update_option() can
 * reach it from anywhere, so it judges the string and nothing else.
 *
 * @param mixed $value Raw submitted value.
 * @return string Value to store.
 */
function keyda_bot_sanitize_client_id( $value ) {
	$previous = (string) get_option( KEYDA_BOT_OPTION, '' );

	// A posted array would raise "Array to string conversion" on the cast
	// below, and there is no reading of one that could ever be a valid id.
	if ( ! is_scalar( $value ) ) {
		return $previous;
	}

	// Keys get copied out of a dashboard and arrive with a stray newline or a
	// leading space more often than not. That is not a wrong key.
	$value = preg_replace( '/\s+/', '', (string) $value );

	// No sanitize_text_field() here, and that is the point: it strips a
	// <script> element down to an empty string, and pasting the whole script
	// tag from the dashboard is the mistake owners actually make. The result
	// would be indistinguishable from clearing the field, so a fat-fingered
	// paste would switch a working bot off and report success. The pattern
	// below is the sanitiser instead — nothing but kb_live_ and hex can
	// survive it, so whatever comes out is safe to store and to print.
	if ( '' === $value ) {
		// Emptying the field is how an owner switches the bot off without
		// deactivating the plugin, so it is a valid save, not an error.
		return '';
	}

	if ( ! keyda_bot_is_valid_client_id( $value ) ) {
		add_settings_error(
			KEYDA_BOT_NOTICES,
			'keyda_bot_client_id_invalid',
			esc_html__( 'That does not look like a Keyda client id, so it was not saved. A client id starts with kb_live_ and is followed by 8 to 48 characters from 0-9 and a-f.', 'keyda-bot' ),
			'error'
		);

		// Keep what was working. A typo in this box must never be able to
		// take a live bot off a live site.
		return $previous;
	}

	return $value;
}

/**
 * Short introduction above the field.
 *
 * @return void
 */
function keyda_bot_render_section_intro() {
	printf(
		'<p>%s</p>',
		sprintf(
			/* translators: %s: link to the Install page of the Keyda Business dashboard. */
			esc_html__( 'Your client id is on the Install page of your Keyda Business dashboard. %s', 'keyda-bot' ),
			sprintf(
				'<a href="%s" target="_blank" rel="noopener noreferrer">%s</a>',
				esc_url( keyda_bot_base_url() . '/app/' ),
				esc_html__( 'Open the dashboard', 'keyda-bot' )
			)
		)
	);
}

/**
 * The one field.
 *
 * @return void
 */
function keyda_bot_render_client_id_field() {
	$value = (string) get_option( KEYDA_BOT_OPTION, '' );

	// True only on the request right after a rejected save, so the message
	// appears against the field that caused it rather than as a page-level
	// notice the owner has to map back to an input.
	$rejected = false;
	foreach ( get_settings_errors( KEYDA_BOT_NOTICES ) as $error ) {
		if ( isset( $error['code'] ) && 'keyda_bot_client_id_invalid' === $error['code'] ) {
			$rejected = true;
			break;
		}
	}

	printf(
		'<input type="text" id="%1$s" name="%1$s" value="%2$s" class="regular-text code" placeholder="kb_live_0000000000000000" autocomplete="off" spellcheck="false"%3$s />',
		esc_attr( KEYDA_BOT_OPTION ),
		esc_attr( $value ),
		$rejected ? ' aria-invalid="true" aria-describedby="keyda-bot-client-id-error"' : ''
	);

	if ( $rejected ) {
		// Inline colour rather than an enqueued stylesheet: one rule on one
		// admin screen is not worth an extra HTTP request on every page of wp-admin.
		printf(
			'<p id="keyda-bot-client-id-error" style="color:#b32d2e;margin:6px 0 0;"><strong>%s</strong> %s</p>',
			esc_html__( 'Not saved.', 'keyda-bot' ),
			esc_html__( 'Paste only the id itself — not the whole <script> tag from the dashboard.', 'keyda-bot' )
		);

		return;
	}

	if ( '' === $value ) {
		printf(
			'<p class="description">%s</p>',
			esc_html__( 'Until this is filled in, the plugin adds nothing to your site.', 'keyda-bot' )
		);

		return;
	}

	printf(
		'<p class="description">%s</p>',
		esc_html__( 'The chat is loading on every page of your site. Open your site in a new tab to see it.', 'keyda-bot' )
	);
}

/**
 * Render the screen.
 *
 * @return void
 */
function keyda_bot_render_settings_page() {
	// Capability check number two. add_options_page() gates the menu, but a
	// page callback is a plain function name that another plugin or a custom
	// admin route can call directly; without this, that path would render the
	// form — and the saved key — to whoever asked.
	if ( ! current_user_can( 'manage_options' ) ) {
		wp_die( esc_html__( 'You are not allowed to change these settings.', 'keyda-bot' ) );
	}
	?>
	<div class="wrap">
		<h1><?php esc_html_e( 'Keyda Bot', 'keyda-bot' ); ?></h1>

		<p>
			<?php esc_html_e( 'This plugin loads the Keyda Bot chat widget on your site. The greeting, colours, languages and answers are all set in your Keyda Business dashboard and change on your site immediately — there is nothing else to configure here.', 'keyda-bot' ); ?>
		</p>

		<?php
		// Prints both our validation error and core's "Settings saved.".
		// Plugin screens under Settings do not load options-head.php, so
		// without this call the messages are collected and never shown.
		settings_errors();
		?>

		<form action="options.php" method="post">
			<?php
			// The nonce and the option_page field. A settings form without
			// this is a CSRF hole: any page an administrator visits could
			// post to options.php and change the key under them.
			settings_fields( KEYDA_BOT_OPTION_GROUP );
			do_settings_sections( KEYDA_BOT_PAGE );
			submit_button( __( 'Save changes', 'keyda-bot' ) );
			?>
		</form>
	</div>
	<?php
}
