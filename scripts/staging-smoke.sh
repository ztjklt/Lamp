#!/bin/sh
set -eu

base_url=${1:?public Supabase function URL is required}
token=${STAGING_USER_JWT:?STAGING_USER_JWT is required}

if [ "${SMOKE_MODE:-full}" = "full" ]; then
  : "${STAGING_SUPABASE_URL:?STAGING_SUPABASE_URL is required for the full smoke test}"
  : "${STAGING_PUBLISHABLE_KEY:?STAGING_PUBLISHABLE_KEY is required for the full smoke test}"
  exec node "$(dirname "$0")/staging-v2-smoke.mjs" "${base_url}"
fi

http_code=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  -H "apikey: ${STAGING_PUBLISHABLE_KEY:-unused}" \
  -H "Authorization: Bearer ${token}" \
  "${base_url%/}/proposals/00000000-0000-4000-8000-000000000000")

# A missing fixture proposal proves that auth and both proxy hops are reachable.
if [ "${http_code}" != "404" ]; then
  echo "unexpected smoke response: ${http_code}" >&2
  exit 1
fi
