#!/bin/sh
set -eu

base_url=${1:?public Supabase function URL is required}
token=${STAGING_USER_JWT:?STAGING_USER_JWT is required}

http_code=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  -H "Authorization: Bearer ${token}" \
  "${base_url%/}/proposals/00000000-0000-4000-8000-000000000000")

# A missing fixture proposal proves that auth and both proxy hops are reachable.
if [ "${http_code}" != "404" ]; then
  echo "unexpected smoke response: ${http_code}" >&2
  exit 1
fi
