#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ ! -f .env ]]; then
  printf '%s\n' 'Missing /work/.env. Copy .env.example to .env and fill in the values first.' >&2
  exit 1
fi

set -a
. ./.env
set +a

: "${KEYCLOAK_DISCOVERY_URL:?KEYCLOAK_DISCOVERY_URL is required}"
: "${KEYCLOAK_CLIENT_ID:?KEYCLOAK_CLIENT_ID is required}"
: "${KEYCLOAK_CLIENT_SECRET:?KEYCLOAK_CLIENT_SECRET is required}"
: "${KEYCLOAK_GROUP_CLAIM_NAME:?KEYCLOAK_GROUP_CLAIM_NAME is required}"
: "${KEYCLOAK_REQUIRED_ROLE:?KEYCLOAK_REQUIRED_ROLE is required}"

oauth_args=(
  --name keycloak
  --provider openidConnect
  --key "$KEYCLOAK_CLIENT_ID"
  --secret "$KEYCLOAK_CLIENT_SECRET"
  --auto-discover-url "$KEYCLOAK_DISCOVERY_URL"
  --scopes 'openid email profile'
  --required-claim-name "$KEYCLOAK_GROUP_CLAIM_NAME"
  --required-claim-value "$KEYCLOAK_REQUIRED_ROLE"
  --group-claim-name "$KEYCLOAK_GROUP_CLAIM_NAME"
)

if [[ -n "${KEYCLOAK_ADMIN_ROLE:-}" ]]; then
  oauth_args+=(--admin-group "$KEYCLOAK_ADMIN_ROLE")
fi

if [[ -n "${KEYCLOAK_RESTRICTED_ROLE:-}" ]]; then
  oauth_args+=(--restricted-group "$KEYCLOAK_RESTRICTED_ROLE")
fi

if [[ -n "${KEYCLOAK_GROUP_TEAM_MAP:-}" && "${KEYCLOAK_GROUP_TEAM_MAP}" != "{}" ]]; then
  oauth_args+=(--group-team-map "$KEYCLOAK_GROUP_TEAM_MAP")
  if [[ "${KEYCLOAK_GROUP_TEAM_MAP_REMOVAL:-false}" == "true" ]]; then
    oauth_args+=(--group-team-map-removal)
  fi
fi

docker compose exec -T gitea gitea admin auth add-oauth "${oauth_args[@]}"
docker compose restart gitea
