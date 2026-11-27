#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f identity.env ]]; then
  echo "Copy identity.env.example to identity.env and customize before building." >&2
  exit 1
fi
set -a; source identity.env; set +a
cat > mac/Config/Identity.xcconfig <<XCC
// Generated from identity.env by scripts/sync-identity.sh. Do not commit.
APP_DISPLAY_NAME = ${APP_DISPLAY_NAME}
PRODUCT_BUNDLE_IDENTIFIER = ${PRODUCT_BUNDLE_IDENTIFIER}
URL_SCHEME = ${URL_SCHEME}
DEVELOPMENT_TEAM = ${DEVELOPMENT_TEAM}
SV_API_HOST = ${SV_API_HOST}
XCC
cat > mac/Config/GoogleCalendar.xcconfig <<XCC
// Optional Google Calendar OAuth client (leave empty for local-only builds).
GOOGLE_CALENDAR_CLIENT_ID = ${GOOGLE_CALENDAR_CLIENT_ID:-}
GOOGLE_CALENDAR_URL_SCHEME = ${GOOGLE_CALENDAR_URL_SCHEME:-}
XCC
echo "IDENTITY_SYNCED ${APP_DISPLAY_NAME} (${PRODUCT_BUNDLE_IDENTIFIER})"
