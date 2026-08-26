<?php
/**
 * WordPress database drop-in: report the real database server version.
 *
 * Pantheon's database proxy answers the MySQL connection handshake with a fixed
 * version string ("5.5.30") regardless of the actual server. WordPress reads that
 * value — wpdb::db_server_info() is a thin wrapper around mysqli_get_server_info(),
 * and wpdb::db_version() just strips the non-numeric part of it — so on Pantheon
 * every environment looks like MySQL 5.5.30, whether it is really MariaDB 10.6 or
 * MySQL 8.4. The handshake also drops the "MariaDB" marker, so code branching on
 * str_contains( $server_info, 'MariaDB' ) fails on MariaDB environments too.
 *
 * SELECT VERSION() returns the truth, so this drop-in overrides db_server_info()
 * to use it and leaves everything else as stock wpdb.
 *
 * Concretely, this makes Tests_DB_Charset behave. Its $utf8_is_utf8mb3 detection
 * requires MariaDB >= 10.6.1 or MySQL >= 8.0.30; at 5.5.30 it never fires, so the
 * tests expect 'utf8_general_ci' while the server reports 'utf8mb3_general_ci'.
 *
 * Installed by prepare.php into <test dir>/src/wp-content/db.php, which
 * require_wp_db() loads before instantiating $wpdb (wp-includes/load.php).
 *
 * @package WordPress
 */

/**
 * wpdb subclass that reports the true server version.
 */
class WPT_Pantheon_Wpdb extends wpdb {

	/**
	 * Cached server version: the real string, false once a lookup has failed,
	 * or null before the first attempt.
	 *
	 * @var string|false|null
	 */
	private $wpt_server_info = null;

	/**
	 * Return the database server version reported by SELECT VERSION().
	 *
	 * This deliberately queries through mysqli rather than $this->get_var().
	 * wpdb::query() performs charset checks that call has_cap(), which calls
	 * db_server_info() — routing this through the normal query path would
	 * recurse infinitely.
	 *
	 * Falls back to the stock handshake value if the connection is not yet open
	 * or the query fails, so this can never make the environment less functional
	 * than plain wpdb.
	 *
	 * @return string
	 */
	public function db_server_info() {
		if ( null !== $this->wpt_server_info ) {
			return ( false === $this->wpt_server_info )
				? parent::db_server_info()
				: $this->wpt_server_info;
		}

		// Called before the connection exists — nothing to query yet. Not cached,
		// so the real lookup still happens once the connection is up.
		if ( empty( $this->dbh ) || ! ( $this->dbh instanceof mysqli ) ) {
			return parent::db_server_info();
		}

		$result = @mysqli_query( $this->dbh, 'SELECT VERSION()' );
		if ( $result instanceof mysqli_result ) {
			$row = $result->fetch_row();
			$result->free();

			if ( ! empty( $row[0] ) ) {
				$this->wpt_server_info = $row[0];
				return $this->wpt_server_info;
			}
		}

		$this->wpt_server_info = false;
		return parent::db_server_info();
	}
}

$wpdb = new WPT_Pantheon_Wpdb( DB_USER, DB_PASSWORD, DB_NAME, DB_HOST );
