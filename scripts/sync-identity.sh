#!/bin/bash
# Generates mac/Config/Identity.xcconfig (and an empty GoogleCalendar.xcconfig stub if absent) from identity.env.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f identity.env ]]; then
  echo "Missing identity.env. Copy identity.env.example to identity.env and customize per TRADEMARK.md." >&2
  exit 1
fi
set -a; source identity.env; set +a
mkdir -p mac/Config
cat > mac/Config/Identity.xcconfig <<XC
// Generated from identity.env by scripts/sync-identity.sh — do not edit.
APP_DISPLAY_NAME = ${APP_DISPLAY_NAME}
APP_DISPLAY_NAME_KO = ${APP_DISPLAY_NAME_KO:-${APP_DISPLAY_NAME}}
PRODUCT_BUNDLE_IDENTIFIER = ${PRODUCT_BUNDLE_IDENTIFIER}
APP_URL_SCHEME = ${URL_SCHEME}
APP_FULL_NAME = ${APP_FULL_NAME:-${APP_DISPLAY_NAME}}
DEVELOPMENT_TEAM = ${DEVELOPMENT_TEAM:-}
XC
if [[ ! -f mac/Config/GoogleCalendar.xcconfig ]]; then
  cat > mac/Config/GoogleCalendar.xcconfig <<'GC'
// Optional: configure a native Google OAuth client for Google Calendar meeting suggestions.
GOOGLE_CALENDAR_CLIENT_ID =
GOOGLE_CALENDAR_URL_SCHEME =
GC
fi
echo "IDENTITY_SYNCED ${APP_DISPLAY_NAME} ${PRODUCT_BUNDLE_IDENTIFIER}"
