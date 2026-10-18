#!/bin/sh
set -eu

# The rootless image currently uses docker-entrypoint.sh. Keep a fallback for
# older Gitea images that used the shorter /usr/bin/entrypoint path.
if [ -x /usr/local/bin/docker-entrypoint.sh ]; then
  GITEA_ENTRYPOINT=/usr/local/bin/docker-entrypoint.sh
elif [ -x /usr/bin/entrypoint ]; then
  GITEA_ENTRYPOINT=/usr/bin/entrypoint
else
  echo "Unable to find the Gitea image entrypoint" >&2
  exit 127
fi

if [ "${KEYCLOAK_AUTO_CONFIGURE:-true}" != "true" ]; then
  exec "$GITEA_ENTRYPOINT" "$@"
fi

# Keep normal Gitea startup available until the OIDC settings are filled in.
if [ -z "${KEYCLOAK_DISCOVERY_URL:-}" ] || \
   [ -z "${KEYCLOAK_CLIENT_ID:-}" ] || \
   [ -z "${KEYCLOAK_CLIENT_SECRET:-}" ] || \
   [ -z "${KEYCLOAK_GROUP_CLAIM_NAME:-}" ] || \
   [ -z "${KEYCLOAK_REQUIRED_ROLE:-}" ]; then
  echo "Keycloak auto-configuration is disabled until complete KEYCLOAK_* settings are supplied" >&2
  exec "$GITEA_ENTRYPOINT" "$@"
fi

configure_keycloak() {
  set -- \
    --name keycloak \
    --provider openidConnect \
    --key "$KEYCLOAK_CLIENT_ID" \
    --secret "$KEYCLOAK_CLIENT_SECRET" \
    --auto-discover-url "$KEYCLOAK_DISCOVERY_URL" \
    --scopes 'openid email profile' \
    --required-claim-name "$KEYCLOAK_GROUP_CLAIM_NAME" \
    --required-claim-value "$KEYCLOAK_REQUIRED_ROLE" \
    --group-claim-name "$KEYCLOAK_GROUP_CLAIM_NAME"

  if [ -n "${KEYCLOAK_ADMIN_ROLE:-}" ]; then
    set -- "$@" --admin-group "$KEYCLOAK_ADMIN_ROLE"
  fi

  if [ -n "${KEYCLOAK_RESTRICTED_ROLE:-}" ]; then
    set -- "$@" --restricted-group "$KEYCLOAK_RESTRICTED_ROLE"
  fi

  if [ -n "${KEYCLOAK_GROUP_TEAM_MAP:-}" ] && [ "$KEYCLOAK_GROUP_TEAM_MAP" != "{}" ]; then
    set -- "$@" --group-team-map "$KEYCLOAK_GROUP_TEAM_MAP"
    if [ "${KEYCLOAK_GROUP_TEAM_MAP_REMOVAL:-false}" = "true" ]; then
      set -- "$@" --group-team-map-removal
    fi
  fi

  gitea admin auth add-oauth "$@"
}

# Start Gitea normally while waiting for the first installation to finish.
"$GITEA_ENTRYPOINT" "$@" &
gitea_pid=$!

terminate_gitea() {
  kill "$gitea_pid" 2>/dev/null || true
  wait "$gitea_pid" 2>/dev/null || true
  exit 143
}

trap terminate_gitea TERM INT

# INSTALL_LOCK is written by Gitea after the initial installation. Waiting for
# it prevents the auth source from being created before the database is ready.
while kill -0 "$gitea_pid" 2>/dev/null; do
  if [ -f /etc/gitea/app.ini ] && \
     grep -Eiq '^[[:space:]]*INSTALL_LOCK[[:space:]]*=[[:space:]]*true[[:space:]]*$' /etc/gitea/app.ini && \
     gitea admin auth list >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! kill -0 "$gitea_pid" 2>/dev/null; then
  wait "$gitea_pid"
  exit $?
fi

if ! gitea admin auth list 2>/dev/null | grep -Eq '(^|[[:space:]])keycloak([[:space:]]|$)'; then
  echo "Creating Gitea Keycloak authentication source" >&2
  if configure_keycloak; then
    echo "Keycloak authentication source created; restarting Gitea" >&2
    kill "$gitea_pid" 2>/dev/null || true
    wait "$gitea_pid" 2>/dev/null || true
    trap - TERM INT
    exec "$GITEA_ENTRYPOINT" "$@"
  else
    echo "Keycloak authentication source could not be created; Gitea will continue without it" >&2
  fi
fi

wait "$gitea_pid"
