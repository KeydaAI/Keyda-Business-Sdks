<?php
/**
 * Runs when the plugin is deleted from the Plugins screen — not on deactivate.
 *
 * Everything this plugin ever wrote is one option holding a client id, and
 * deleting the plugin should leave the database as it found it.
 *
 * @package Keyda_Bot
 */

// WordPress defines this only when it is the one including this file. Without
// the guard, a direct request to /wp-content/plugins/keyda-bot/uninstall.php
// would be an unauthenticated way to run it.
defined( 'WP_UNINSTALL_PLUGIN' ) || exit;

/*
 * The option name is repeated here rather than read from KEYDA_BOT_OPTION:
 * WordPress runs uninstall.php in a fresh request with the plugin's own files
 * never loaded, so that constant does not exist at this point. If the name in
 * keyda-bot.php ever changes, change it here too.
 */
$keyda_bot_options = array( 'keyda_bot_client_id', 'keyda_bot_branding' );

if ( is_multisite() ) {
	// Each site in the network stores its own key, so deleting only the
	// current site's row would leave the rest behind for good.
	foreach ( get_sites( array( 'fields' => 'ids', 'number' => 0 ) ) as $keyda_bot_site_id ) {
		switch_to_blog( (int) $keyda_bot_site_id );
		foreach ( $keyda_bot_options as $keyda_bot_option ) {
			delete_option( $keyda_bot_option );
		}
		restore_current_blog();
	}
} else {
	foreach ( $keyda_bot_options as $keyda_bot_option ) {
		delete_option( $keyda_bot_option );
	}
}
