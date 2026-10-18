# Gitea with Keycloak

This stack runs rootless Gitea at `https://git.kmode.dev`, with PostgreSQL and OpenID Connect login backed by the Keycloak realm configured in `KEYCLOAK_DISCOVERY_URL`. Apache can terminate TLS and proxy the web listener on the configurable local bind address; SSH has its own configurable bind address and port.

## 1. Create the Keycloak client

In the realm identified by `KEYCLOAK_DISCOVERY_URL` at `https://auth.kmode.dev`, create a client with:

- Client ID: `gitea` (or the value of `KEYCLOAK_CLIENT_ID`)
- Client authentication: enabled
- Standard flow: enabled
- Direct access grants: disabled
- Valid redirect URI: `https://git.kmode.dev/user/oauth2/keycloak/callback`
- Web origin: `https://git.kmode.dev`

Copy the generated client secret into `KEYCLOAK_CLIENT_SECRET` in `.env`.

Keycloak should provide the standard `openid`, `profile`, and `email` scopes. The Gitea configuration requests `email profile` in addition to the implicit `openid` scope.

## 2. Start Gitea

```sh
cp .env.example .env
chmod 600 .env
# Edit .env and set the public Gitea URL, Keycloak client secret, and roles.
docker compose up -d
```

Open `https://git.kmode.dev`. On the first visit, complete Gitea’s setup page and create the bootstrap administrator if the installer asks for one. After the installer writes `INSTALL_LOCK`, the Compose entrypoint automatically creates the Keycloak source and restarts Gitea. Password sign-in is disabled by default, so normal access is provided by Keycloak. The database values are already supplied by Compose, so the database host is `db` and the database name, user, and password are already filled in.

If you need to use the bootstrap account during setup, temporarily set `GITEA_ENABLE_PASSWORD_SIGNIN_FORM=true` and `GITEA_ENABLE_BASIC_AUTHENTICATION=true` in `.env`, run `docker compose up -d`, and set both values back to `false` after Keycloak login works.

## 3. Configure Keycloak client roles

Keycloak normally puts client roles under the nested `resource_access` claim. Gitea’s group and required-claim fields work best with a flat multivalued claim, so add a `User Client Role` protocol mapper to the `gitea` client:

- Client ID: the value of `KEYCLOAK_CLIENT_ID`
- Token Claim Name: the value of `KEYCLOAK_GROUP_CLAIM_NAME` (default: `gitea_roles`)
- Multivalued: enabled
- Add to ID token: enabled
- Add to access token: enabled
- Add to userinfo: enabled

The mapper must emit only this client’s roles. Keycloak provides this mapper specifically for mapping a user’s client roles into an OIDC claim. ([Keycloak mapper reference](https://www.keycloak.org/docs-api/latest/javadocs/org/keycloak/protocol/oidc/mappers/UserClientRoleMappingMapper.html))

Create these client roles, or change the names in `.env`:

- `KEYCLOAK_REQUIRED_ROLE`: required for login
- `KEYCLOAK_ADMIN_ROLE`: grants the Gitea administrator flag
- `KEYCLOAK_RESTRICTED_ROLE`: grants the Gitea restricted-user flag
- Roles in `KEYCLOAK_GROUP_TEAM_MAP`: map to Gitea organization teams

The required role is enforced before account creation, so a Keycloak user without it cannot log in. Team permissions come from the target Gitea teams; configure each team’s repository permission in Gitea.

## 4. Add or update the Keycloak login source

In Gitea, open `Site Administration -> Identity & Access -> Authentication Sources -> Add Authentication Source` and select `OAuth2`.

Use these values:

- Authentication Name: `keycloak`
- OAuth2 Provider: `OpenID Connect`
- Client ID: the value of `KEYCLOAK_CLIENT_ID`
- Client Secret: the value of `KEYCLOAK_CLIENT_SECRET`
- OpenID Connect Auto Discovery URL: the value of `KEYCLOAK_DISCOVERY_URL`
- Additional Scopes: `profile email` (already supplied globally by the Compose configuration)
- Required Claim Name: the value of `KEYCLOAK_GROUP_CLAIM_NAME`
- Required Claim Value: the value of `KEYCLOAK_REQUIRED_ROLE`
- Claim name providing group names: the value of `KEYCLOAK_GROUP_CLAIM_NAME`
- Group Claim value for administrator users: the value of `KEYCLOAK_ADMIN_ROLE`
- Group Claim value for restricted users: the value of `KEYCLOAK_RESTRICTED_ROLE`
- Map claimed groups to Organization teams: the value of `KEYCLOAK_GROUP_TEAM_MAP`
- Remove team membership when a role is removed: the value of `KEYCLOAK_GROUP_TEAM_MAP_REMOVAL`

Save the source and test `Sign in with keycloak` in a private browser window. The callback URL must exactly match the URI registered in Keycloak.

The source is normally created automatically after the initial Gitea setup. To create it manually or recreate it after deleting it, use:

```sh
bash /work/configure-keycloak.sh
```

The script uses all role and team settings from `.env`, then restarts Gitea after creating the source. If `keycloak` already exists, update its values in the Gitea UI or remove the source before running the script again.

## Reverse proxy

The example `.env` binds Gitea’s web listener to `127.0.0.1:10301`, so it is not exposed directly. Use the configured `GITEA_HTTP_BIND_PORT` in the Apache virtual host:

```apache
<VirtualHost *:443>
    ServerName git.kmode.dev

    SSLEngine on
    # SSLCertificateFile and SSLCertificateKeyFile go here.

    ProxyPreserveHost On
    RequestHeader set X-Forwarded-Proto "https"
    RequestHeader set X-Forwarded-Host "git.kmode.dev"
    ProxyPass        / http://127.0.0.1:10301/
    ProxyPassReverse / http://127.0.0.1:10301/
</VirtualHost>
```

Enable Apache’s `proxy`, `proxy_http`, `headers`, and `ssl` modules. Forward the usual `Host`, `X-Forwarded-Proto`, and `X-Forwarded-For` headers. SSH is published independently on `${GITEA_SSH_BIND_ADDRESS:-0.0.0.0}:${GITEA_SSH_BIND_PORT:-2222}`.

## Operations

```sh
docker compose ps
docker compose logs -f gitea
docker compose pull
docker compose up -d
```

The Gitea, configuration, and PostgreSQL data are stored in Docker named volumes. Back up those volumes before upgrades or host maintenance.
