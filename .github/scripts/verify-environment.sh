#!/bin/bash
#
# Verify that a Pantheon multidev is actually running the PHP / MariaDB versions
# the test matrix expects. Queries the container's live PHP_VERSION and MariaDB
# SELECT VERSION() so a drifted pantheon.yml can't silently run (and report) the
# wrong environment to WordPress.org.
#
# Required environment:
#   PANTHEON_SITE  Site and environment, e.g. wp-org-test-fixture.php84-db106
#   EXPECT_PHP     Expected PHP major.minor (e.g. 8.4)
#   EXPECT_DB      Expected MariaDB major.minor (e.g. 10.6)
#
# Optional:
#   GITHUB_STEP_SUMMARY  Written to when set; falls back to stdout locally.
#
# Exits non-zero on mismatch, or if the environment can't be queried at all.

set -uo pipefail

for var in PANTHEON_SITE EXPECT_PHP EXPECT_DB; do
	if [ -z "${!var:-}" ]; then
		echo "::error::${var} is not set" >&2
		exit 1
	fi
done

SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

# PHP snippet run on the container by terminus; $m/$v are PHP vars, so single
# quotes (no shell expansion) are deliberate.
# shellcheck disable=SC2016
INFO='$m=@new mysqli(getenv("DB_HOST"),getenv("DB_USER"),getenv("DB_PASSWORD"),getenv("DB_NAME"),(int)getenv("DB_PORT")); $v=($m && !$m->connect_errno)?$m->query("SELECT VERSION()")->fetch_row()[0]:"unknown"; echo json_encode(["php"=>PHP_VERSION,"db"=>$v]);'

STDERR=$(mktemp)
trap 'rm -f "$STDERR"' EXIT

JSON=$(terminus remote:wp "$PANTHEON_SITE" -- eval "$INFO" --skip-wordpress --quiet 2>"$STDERR")
if [ -z "$JSON" ] || ! jq -e . >/dev/null 2>&1 <<<"$JSON"; then
	echo "::error::Could not read version info from ${PANTHEON_SITE}. terminus returned:"
	echo "${JSON:-(empty)}"
	cat "$STDERR" >&2
	exit 1
fi

echo "Environment reports: $JSON"

ACTUAL_PHP=$(jq -r '.php // "unknown"' <<<"$JSON")
ACTUAL_DB=$(jq -r '.db // "unknown"' <<<"$JSON")
ACTUAL_PHP_MM=$(grep -oE '^[0-9]+\.[0-9]+' <<<"$ACTUAL_PHP")
ACTUAL_DB_MM=$(grep -oE '[0-9]+\.[0-9]+' <<<"$ACTUAL_DB" | head -1)

echo "PHP     — expected ${EXPECT_PHP}, actual ${ACTUAL_PHP}"
echo "MariaDB — expected ${EXPECT_DB}, actual ${ACTUAL_DB}"

STATUS="✅ match"
if [ "$ACTUAL_PHP_MM" != "$EXPECT_PHP" ]; then
	echo "::error::PHP mismatch on ${PANTHEON_SITE}: reports ${ACTUAL_PHP}, matrix expects ${EXPECT_PHP}"
	STATUS="❌ mismatch"
fi
if [ "$ACTUAL_DB_MM" != "$EXPECT_DB" ]; then
	echo "::error::MariaDB mismatch on ${PANTHEON_SITE}: reports ${ACTUAL_DB}, matrix expects ${EXPECT_DB}"
	STATUS="❌ mismatch"
fi

{
	echo "### Environment verification — ${PANTHEON_SITE} (${STATUS})"
	echo ""
	echo "| | Expected | Actual |"
	echo "|---|---|---|"
	echo "| PHP | ${EXPECT_PHP} | ${ACTUAL_PHP} |"
	echo "| MariaDB | ${EXPECT_DB} | ${ACTUAL_DB} |"
} >>"$SUMMARY"

[ "$STATUS" = "✅ match" ]
