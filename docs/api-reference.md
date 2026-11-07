# API reference

This document catalogues every endpoint this backend exposes, for building a
client (such as a replacement account dashboard) against it. It reflects the
schema as of migration `00000000000016`.

The backend is a self-hosted Supabase-style stack: Kong gateway in front of
PostgREST, GoTrue auth, Storage, and a set of Deno edge functions. There is
no bespoke REST framework here — almost everything client-facing is a
Postgres function called through PostgREST's RPC convention
(`POST /rest/v1/rpc/<function_name>`).

## 1. Overview & routing

All requests go through Kong (`volumes/api/kong.yml`). Locally, Kong listens
on `http://localhost:8000`; in production it's reached through the deployment's
public HTTPS URL. The account dashboard UI (if any) is served separately
(`http://localhost:3000` locally) and is not part of this API.

| Path prefix | Upstream | Auth required at gateway |
| --- | --- | --- |
| `/.well-known/nuvio` | terminated in Kong, no upstream | none |
| `/.well-known/oauth-authorization-server` | `auth:9999` | none |
| `/auth/v1/verify`, `/auth/v1/callback`, `/auth/v1/authorize`, `/auth/v1/.well-known/jwks.json` | `auth:9999` | none |
| `/sso/saml/acs`, `/sso/saml/metadata` | `auth:9999` | none |
| `/auth/v1/*` (all other routes) | `auth:9999` | `apikey` header + ACL |
| `/rest/v1/*` | `rest:3000` (PostgREST) | `apikey` header + ACL |
| `/graphql/v1` | `rest:3000/rpc/graphql` | `apikey` header + ACL |
| `/realtime/v1/*` | `realtime-dev.supabase-realtime:4000` (websocket) | `apikey` header + ACL |
| `/storage/v1/*` | `storage:5000` | `Authorization` header only (no `apikey` required; S3-compatible signing also supported) |
| `/functions/v1/*` | `functions:9000` (edge runtime) | none at gateway — each function authenticates itself |
| `/pg/*` | `meta:8080` (pg-meta) | `apikey` header + ACL, `admin` group only |

Every gated route expects an `apikey` header (or query param) equal to the
deployment's publishable key. Once signed in, also send
`Authorization: Bearer <user JWT>` — a Lua expression at the gateway
translates the apikey into the right downstream identity, but the user JWT is
what scopes RPC calls to a specific account.

### Recommended bootstrap flow

1. `GET /.well-known/nuvio` (no auth) to discover the backend:
   ```json
   {
     "version": 1,
     "service": "nuvio",
     "self_hosted": true,
     "backend_url": "<SUPABASE_PUBLIC_URL>",
     "publishable_key": "<NUVIO_PUBLIC_API_KEY>",
     "capabilities": { "email_password_auth": true, "tv_login": true }
   }
   ```
2. Use `backend_url` + `publishable_key` as the `apikey` for all subsequent
   calls.
3. Authenticate via the GoTrue endpoints (section 2) to obtain a user JWT.

## 2. Auth (GoTrue)

Standard Supabase Auth (`supabase/gotrue`) routes under `/auth/v1/*`. Notable
self-hosted defaults (`compose.yml`, `auth` service env): email is
auto-confirmed (`GOTRUE_MAILER_AUTOCONFIRM=true` by default, no SMTP
required), and anonymous sign-in is enabled by default
(`GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED=true`). Access tokens expire after
`JWT_EXPIRY` seconds (default 7200). No custom auth hooks are active.

| Route | Method | Purpose |
| --- | --- | --- |
| `/auth/v1/signup` | POST | Email/password sign up |
| `/auth/v1/token?grant_type=password` | POST | Sign in |
| `/auth/v1/token?grant_type=refresh_token` | POST | Refresh session |
| `/auth/v1/logout` | POST | Sign out (revokes current session) |
| `/auth/v1/recover` | POST | Send password-reset email |
| `/auth/v1/otp` | POST | Request magic link / OTP |
| `/auth/v1/verify` | GET | Verify OTP / magic link / confirmation token (open route) |
| `/auth/v1/user` | GET / PUT | Get / update current user |
| `/auth/v1/.well-known/jwks.json` | GET | Public keys for JWT verification (open route) |
| `/auth/v1/authorize`, `/auth/v1/callback` | GET/POST | OAuth provider flow (open routes) |
| `/auth/v1/admin/*` | various | Admin-only (service role), e.g. used internally by the `delete-account` edge function |

## 3. RPC reference

All RPCs are called as `POST /rest/v1/rpc/<name>` with a JSON body of named
parameters, `apikey` header, and (except where noted `anon`) an
`Authorization: Bearer <user JWT>` header. Unless noted otherwise, every
function is `SECURITY DEFINER` and internally resolves the caller via
`get_sync_owner()` (raises `28000` if unauthenticated), so results are always
scoped to the calling account — there is no `user_id` parameter to pass.

Functions granted to `anon` (usable without signing in first):
`get_avatar_catalog()`, `health_ping()`, `poll_tv_login_session`,
`start_tv_login_session`, `start_tracker_tv_login_session`,
`poll_tracker_tv_login_session`.

### 3.1 Sessions & devices

| Function | Params | Returns | Notes |
| --- | --- | --- | --- |
| `list_my_sessions()` | — | `TABLE(session_id uuid, created_at timestamptz, last_active_at timestamptz, client_name text, client_version text, platform text, device_name text, user_agent text, is_current boolean)` | Active sessions, current session first. |
| `register_current_device(p_installation_id text, p_client_name text, p_client_version text DEFAULT NULL, p_platform text DEFAULT NULL, p_device_name text DEFAULT NULL)` | → `boolean` | Upserts a device row. Validates installation id (16-96 chars, `[A-Za-z0-9_-]+`) and client name against an allow-list (`Nuvio Web/Mobile/TV/Desktop`). Revokes any other session previously bound to the same installation id. |
| `register_current_session(p_client_name text, p_client_version text DEFAULT NULL, p_platform text DEFAULT NULL, p_device_name text DEFAULT NULL)` | → `boolean` | Wrapper over `register_current_device` using a synthetic id derived from the JWT session id. |
| `revoke_my_session(p_session_id uuid)` | → `boolean` | Deletes an `auth.sessions` row. Raises `22023` if you pass your own session id (use local sign-out instead). |

### 3.2 TV / companion-device pairing

| Function | Params | Returns | Notes |
| --- | --- | --- | --- |
| `start_tv_login_session(p_device_nonce text, p_redirect_base_url text, p_device_name text DEFAULT NULL)` | → `TABLE(code text, web_url text, expires_at timestamptz, poll_interval_seconds integer)` | `anon`. Nonce ≥12 chars, redirect URL must contain `/tv-login`. Rate-limited to 200 new sessions/min. 5-minute TTL. |
| `poll_tv_login_session(p_code text, p_device_nonce text)` | → `TABLE(status text, expires_at timestamptz, poll_interval_seconds integer)` | `anon`. Auto-expires after 240 polls. |
| `approve_tv_login_session(p_code text)` | → `TABLE(success boolean, message text)` | Requires signed-in session. Returns `(false, ...)` rather than raising on an unknown/expired code. |
| `start_device_login_session(p_device_nonce text, p_redirect_base_url text, p_device_name text DEFAULT NULL, p_device_type text DEFAULT 'device')` | → `TABLE(device_code text, user_code text, verification_uri text, verification_uri_complete text, expires_at timestamptz, poll_interval_seconds integer)` | `anon`. Short-code device linking, an alternative to the `start_tv_login_session` flow. Nonce ≥12 chars; redirect URL must be http(s), contain `/link`, and have no query string or fragment. `user_code` is the six-character code the device displays; `verification_uri_complete` is the redirect URL with `?code=<user_code>` appended. Rate-limited on new sessions per minute; 5-minute TTL. The device then polls with `poll_tv_login_session(device_code, nonce)` and finishes with the `tv-logins-exchange` edge function, exactly as with the TV flow. Added in migration `00000000000014`. |
| `get_device_login_session(p_user_code text)` | → `TABLE(success boolean, message text, user_code text, device_name text, device_type text, expires_at timestamptz)` | Requires signed-in session. Looks up a pending session by user code so the approver can confirm which device they are linking. Returns `(false, ...)` rather than raising for an unknown/expired code, but attempts are limited to 5 per user per 5 minutes (raises `Too many device code attempts`). |
| `approve_device_login_session(p_user_code text)` | → `TABLE(success boolean, message text, device_name text, device_type text)` | Requires signed-in session. Approves the session so the device's poll/exchange succeeds. Shares the attempt limit with `get_device_login_session`. |
| `start_tracker_tv_login_session(p_tracker text, p_device_nonce text, p_redirect_base_url text)` | → `TABLE(code text, web_url text, expires_at timestamptz, poll_interval_seconds integer)` | `anon`. `p_tracker` in `mal`/`anilist`/`kitsu`. |
| `poll_tracker_tv_login_session(p_tracker text, p_code text, p_device_nonce text)` | → `TABLE(status text, access_token text, refresh_token text, expires_in integer, user_id text, username text, poll_interval_seconds integer)` | `anon`. `status` is `pending`/`ready`/`expired`. |

### 3.3 Profiles

| Function | Params | Returns | Notes |
| --- | --- | --- | --- |
| `sync_pull_profiles()` | — | `TABLE(id uuid, user_id uuid, profile_index integer, name text, avatar_color_hex text, uses_primary_addons boolean, uses_primary_plugins boolean, avatar_id text, avatar_url text, pin_enabled boolean, pin_locked_until timestamptz, created_at timestamptz, updated_at timestamptz)` | Ordered by `profile_index`. |
| `sync_push_profiles(p_profiles jsonb, p_client_max_profiles integer, p_origin_client_id text)` | → `void` | Upserts the supplied profiles and **does not delete profiles omitted from the array** (use `sync_delete_profile_data` for explicit deletion). `p_client_max_profiles` must be 1-6. Profile index 1 always has `uses_primary_addons/plugins = false`. |
| `sync_patch_profile(p_profile_id integer, p_name text DEFAULT NULL, p_avatar_color_hex text DEFAULT NULL, p_uses_primary_addons boolean DEFAULT NULL, p_uses_primary_plugins boolean DEFAULT NULL, p_avatar_url text DEFAULT NULL, p_avatar_url_provided boolean DEFAULT false, p_avatar_id text DEFAULT NULL, p_avatar_id_provided boolean DEFAULT false, p_profile_background_id text DEFAULT NULL, p_profile_background_id_provided boolean DEFAULT false, p_profile_background_url text DEFAULT NULL, p_profile_background_url_provided boolean DEFAULT false)` | `TABLE(id, user_id, profile_index, name, avatar_color_hex, uses_primary_addons, uses_primary_plugins, avatar_id, avatar_url, profile_background_id, profile_background_url, created_at, updated_at)` | **Preferred way to edit a single profile.** Sparse patch — only fields whose `*_provided` flag is true are changed. See §7 for the profile-background caveat. |
| `sync_delete_profile_data(p_profile_id integer, p_origin_client_id text)` | → `void` | Deletes the profile and all profile-scoped data (addons, plugins, collections, settings, watch progress, watched items, tracker data, audit logs). The watch-progress, watched-item and library delta events are **kept**, including the delete events the removal emits, so other devices holding a cursor learn about the deletions (migration `00000000000016`). Account deletion still removes them. |
| `sync_copy_profile_setup(p_source_profile_id integer, p_target_profile_id integer, p_copy_tv boolean DEFAULT true, p_copy_mobile boolean DEFAULT false, p_copy_desktop boolean DEFAULT false, p_copy_provider_credentials boolean DEFAULT false, p_replace_provider_credentials boolean DEFAULT false, p_origin_client_id text DEFAULT NULL)` | `TABLE(source_profile_id integer, target_profile_id integer, tv_status text, mobile_status text, desktop_status text, provider_credentials_status text)` | Copies the per-platform settings blobs and, optionally, the provider credentials from one profile to another. Both profiles must already exist (profile ids 1-6, source ≠ target), otherwise it raises `22023`. `*_status` is `copied` or `unchanged` (also `unchanged` when the platform was not requested or the source has no blob). `provider_credentials_status` is `copied`, `copied_partial` (some rows copied, some kept), `kept_existing` (target rows differ and `p_replace_provider_credentials` is false), `unchanged` or `source_missing`. Nuvio TV validates these values. Added in migration `00000000000016`. |
| `sync_pull_profile_locks()` | — | `TABLE(profile_index integer, pin_enabled boolean, pin_locked_until timestamptz)` | Lightweight PIN-lock status for rendering locked profile tiles. |
| `set_profile_pin(p_profile_id integer, p_pin text, p_current_pin text DEFAULT NULL)` | → `void` | PIN must be exactly 4 digits. `p_current_pin` required if a PIN is already set. |
| `clear_profile_pin(p_profile_id integer, p_current_pin text DEFAULT NULL)` | → `void` | Requires current PIN. |
| `clear_profile_pin_with_account_password(p_account_password text, p_profile_id integer)` | → `void` | Recovery path: verifies the account password instead of the PIN. |
| `verify_profile_pin(p_profile_id integer, p_pin text)` | → `TABLE(unlocked boolean, retry_after_seconds integer)` | Implements lockout/backoff. Does not raise on a wrong PIN — check `unlocked`. |
| `get_sync_overview()` | — | `jsonb` | Per-profile counts (addons/plugins/library/progress/watched) plus a `{profile_index: {name, color}}` map. Good for a dashboard summary widget. |

### 3.4 Library (saved/bookmarked content)

| Function | Params | Returns | Notes |
| --- | --- | --- | --- |
| `sync_pull_library(p_profile_id integer DEFAULT 1, p_limit integer DEFAULT 500, p_offset integer DEFAULT 0)` | `SETOF library_items` | Ordered by `added_at DESC, id` (stable offset paging; tiebreaker added in migration `00000000000015`). Rows include an optional `logo` URL (added in migration `00000000000014`; accepted by the library push RPCs and returned by the delta feed). |
| `sync_pull_library_delta(p_profile_id integer DEFAULT 1, p_since_event_id bigint DEFAULT 0, p_limit integer DEFAULT 1000)` | `TABLE(event_id, operation, content_id, content_type, name, poster, poster_shape, background, description, release_info, imdb_rating, genres, addon_base_url, added_at, logo)` | Incremental feed; `operation` is `upsert`/`delete`. `p_limit` clamped 1-1000. |
| `sync_get_library_delta_cursor(p_profile_id integer DEFAULT 1)` | → `bigint` | Latest `event_id`, for bootstrapping delta polling. |
| `sync_push_library_items(p_items jsonb, p_profile_id integer DEFAULT 1, p_origin_client_id text DEFAULT NULL)` | → `void` | **Preferred push RPC** (item-level upsert). |
| `sync_delete_library_items(p_keys jsonb, p_profile_id integer DEFAULT 1, p_origin_client_id text DEFAULT NULL)` | → `void` | Deletes by array of `{content_id, content_type}`. |

### 3.5 Watch progress ("continue watching")

| Function | Params | Returns | Notes |
| --- | --- | --- | --- |
| `sync_pull_watch_progress(p_profile_id integer DEFAULT 1, p_since_last_watched bigint DEFAULT NULL, p_limit integer DEFAULT NULL)` | `SETOF watch_progress` | Ordered by `last_watched DESC`. |
| `sync_pull_watch_progress_delta(p_profile_id integer DEFAULT 1, p_since_event_id bigint DEFAULT 0, p_limit integer DEFAULT 1000)` | `TABLE(event_id, operation, progress_key, content_id, content_type, video_id, season, episode, position, duration, last_watched)` | Delta feed. |
| `sync_get_watch_progress_delta_cursor(p_profile_id integer DEFAULT 1)` | → `bigint` | |
| `sync_push_watch_progress(p_entries jsonb, p_profile_id integer, p_origin_client_id text)` | → `void` | Batch upsert. Crossing a completion threshold automatically creates/updates a corresponding `watched_items` row. Stale pushes are ignored: an older entry will not move progress backwards, resurrect progress another device removed, or reopen an item marked watched after the pushed position. |
| `sync_delete_watch_progress(p_keys jsonb, p_profile_id integer, p_origin_client_id text)` | → `void` | Deletes by `progress_key` array. |

### 3.6 Watched items (history)

| Function | Params | Returns | Notes |
| --- | --- | --- | --- |
| `sync_pull_watched_items(p_profile_id integer DEFAULT 1, p_page integer DEFAULT 1, p_page_size integer DEFAULT 100000)` | `SETOF watched_items` | Raw per-episode rows, `watched_at DESC, id` (the `id` tiebreaker, added in migration `00000000000015`, keeps offset pages free of repeats and gaps when rows share a timestamp), plain offset pagination. **Use this for full local sync** (e.g. mobile/TV clients replicating exact per-episode state) — it does not group by series, so a series' episodes can appear on different pages. |
| `sync_pull_watched_items_grouped(p_profile_id integer DEFAULT 1, p_page integer DEFAULT 1, p_page_size integer DEFAULT 50)` | `TABLE(content_id text, content_type text, title text, season integer, episode integer, watched_at bigint, furthest_season integer, furthest_episode integer, furthest_watched_at bigint, episode_count integer)` | **Use this for a history/"watched" UI list.** One row per `content_id` (movie or series), with two independent episode pointers: `season`/`episode`/`watched_at` describe the episode tied to the most recent watch activity — the actual last-watched episode, which may be an *earlier* episode than the show's progress if it was rewatched — use this for "last watched S1E1 on \<date\>" UI. `watched_at` is `max(watched_at)` across the whole group ("last activity on this title") and is what pagination/ordering use. `furthest_season`/`furthest_episode`/`furthest_watched_at` describe the *furthest-along* watched entry in the group (highest season, then highest episode) — use this for "continue watching S3E26" UI. `title`/`content_type` come from the most-recently-watched row. `episode_count` is the number of distinct watched episodes in the group, or `NULL` for movies/items with no episode data. Paginated over groups, so a series can never be split across pages, and results are already in reverse-chronological order by most recent activity. Added in migration `00000000000011`; the furthest-along/last-watched split (`furthest_season`, `furthest_episode`, `furthest_watched_at`) added in migration `00000000000013`. |
| `sync_pull_watched_items_delta(p_profile_id integer DEFAULT 1, p_since_event_id bigint DEFAULT 0, p_limit integer DEFAULT 1000)` | `TABLE(event_id, operation, content_id, content_type, title, season, episode, watched_at)` | Delta feed of raw rows. |
| `sync_get_watched_items_delta_cursor(p_profile_id integer DEFAULT 1)` | → `bigint` | |
| `sync_push_watched_items(p_items jsonb, p_profile_id integer, p_origin_client_id text)` | → `void` | Upsert by `(content_id, season, episode)`. |
| `sync_delete_watched_items(p_keys jsonb, p_profile_id integer, p_origin_client_id text)` | → `void` | Deletes by `{content_id, season, episode}` keys. |

### 3.7 Addons / plugins

| Function | Params | Returns | Notes |
| --- | --- | --- | --- |
| `sync_push_addons(p_addons jsonb, p_profile_id integer, p_origin_client_id text)` | → `void` | Full replace per profile, hash-diffed to skip no-op writes. If a URL appears more than once in the payload the last entry wins (migration `00000000000016`; earlier versions rejected the whole push). |
| `sync_push_plugins(p_plugins jsonb, p_profile_id integer, p_origin_client_id text)` | → `void` | Same pattern, including the repeated-URL rule. |

There is no dedicated `sync_pull_addons`/`sync_pull_plugins` RPC — read the
`addons`/`plugins` tables directly via PostgREST (RLS-scoped to the caller;
see §4), or use `sync_export_account_backup`.

### 3.8 Home catalog settings

| Function | Params | Returns | Notes |
| --- | --- | --- | --- |
| `sync_pull_home_catalog_settings(p_profile_id integer, p_platform text DEFAULT 'tv')` | `SETOF home_catalog_settings` | Platform-scoped. |
| `sync_push_home_catalog_settings(p_profile_id integer, p_settings_json jsonb, p_platform text, p_origin_client_id text)` | → `void` | |

### 3.9 Profile settings blob (generic per-profile JSON store)

| Function | Params | Returns | Notes |
| --- | --- | --- | --- |
| `sync_pull_profile_settings_blob(p_profile_id integer, p_platform text DEFAULT 'tv')` | `TABLE(profile_id integer, settings_json jsonb, updated_at timestamptz)` | |
| `sync_push_profile_settings_blob(p_profile_id integer, p_settings_json jsonb, p_platform text, p_origin_client_id text)` | → `void` | Blind overwrite, no concurrency guard. |
| `sync_push_profile_settings_blob_guarded(p_profile_id integer, p_settings_json jsonb, p_platform text, p_expected_updated_at timestamptz)` | → `timestamptz` | **Preferred write path for a dashboard.** Optimistic concurrency: `p_expected_updated_at` must match the row's current `updated_at` (or be `NULL` if no row exists yet), else raises `PT409 Settings changed on another device. Reload and try again.`, which PostgREST returns as **HTTP 409** (it is not a retried `40001`). Returns the new `updated_at` to re-arm the guard. For the `tv` platform, `features.player_settings.subtitle_{text,background,outline}_color` values are normalized server-side to signed 32-bit ARGB ints (e.g. `{"type":"int","value":-1}`). |

### 3.9a Media servers

| Function | Params | Returns | Notes |
| --- | --- | --- | --- |
| `sync_pull_media_servers(p_profile_id integer)` | `TABLE(servers_json jsonb, updated_at timestamptz)` | Zero or one row. `servers_json` is an array of server objects (`id`, `provider_id`, `name`, `address`, `remote_server_id`, `remote_user_id`, `user_name`, `token`, `enabled`, `use_catalog_metadata`, `libraries[]`). Profile id 1-6. |
| `sync_push_media_servers(p_profile_id integer, p_servers jsonb, p_origin_client_id text)` | → `timestamptz` | Replaces the profile's server list. At most 16 servers (duplicate ids rejected) and 500 libraries per server; fields are trimmed and length-checked. Returns the new `updated_at`. |

Server entries include access tokens, so `media_servers` has no table grants for
`anon`/`authenticated` and is RPC-only. Rows are removed by
`sync_delete_profile_data` and account deletion. Added in migration
`00000000000014`.

### 3.10 Collections

| Function | Params | Returns | Notes |
| --- | --- | --- | --- |
| `sync_pull_collections(p_profile_id integer)` | `TABLE(profile_id integer, collections_json jsonb, updated_at timestamptz)` | |
| `sync_push_collections(p_profile_id integer, p_collections_json jsonb, p_origin_client_id text)` | → `void` | |

### 3.11 Provider credentials (debrid services, TMDB, MDBList, IntroDB, AnimeSkip)

| Function | Params | Returns | Notes |
| --- | --- | --- | --- |
| `sync_pull_provider_credentials(p_profile_id integer)` | `TABLE(provider text, credential_json jsonb, updated_at timestamptz)` | Only returns allow-listed providers: `debrid:torbox`, `debrid:premiumize`, `debrid:realdebrid`, `tmdb`, `mdblist`, `animeskip`, `introdb`. |
| `sync_push_provider_credentials(p_profile_id integer, p_credentials jsonb, p_origin_client_id text)` | → `void` | |
| `sync_seed_provider_credentials(p_profile_id integer, p_credentials jsonb, p_origin_client_id text)` | → `void` | Insert-only (`ON CONFLICT DO NOTHING`) — won't clobber an existing credential. Max 16 items, no duplicate providers per call. |
| `sync_delete_provider_credentials(p_profile_id integer, p_provider text, p_origin_client_id text)` | → `void` | No-op if `p_provider` is blank. |

### 3.12 Tracker integrations (MyAnimeList / AniList / Kitsu)

| Function | Params | Returns | Notes |
| --- | --- | --- | --- |
| `get_profile_tracker_settings(p_profile_id integer)` | `SETOF profile_tracker_settings` | |
| `upsert_profile_tracker_settings(p_profile_id integer, p_tracker text, p_enabled_statuses text[], p_row_order text[], p_send_progress boolean)` | → `void` | `p_tracker` in `mal`/`anilist`/`kitsu`. |
| `get_tracker_tokens(p_profile_id integer)` | `SETOF user_tracker_tokens` | Contains OAuth access/refresh tokens — sensitive, do not log. |
| `upsert_tracker_tokens(p_profile_id integer, p_tracker text, p_access_token text, p_refresh_token text, p_expires_in_seconds integer, p_tracker_user_id text, p_username text)` | → `void` | |
| `clear_tracker_tokens(p_profile_id integer, p_tracker text)` | → `void` | |

### 3.13 Activity telemetry

| Function | Params | Returns | Notes |
| --- | --- | --- | --- |
| `record_activity_event(p_event_type text, p_status text, p_profile_id integer DEFAULT NULL, p_platform text DEFAULT 'unknown', p_app_version text DEFAULT NULL, p_device_id text DEFAULT NULL, p_device_name text DEFAULT NULL, p_entity_type text DEFAULT NULL, p_entity_key text DEFAULT NULL, p_action text DEFAULT NULL, p_duration_ms integer DEFAULT NULL, p_item_count integer DEFAULT NULL, p_error_code text DEFAULT NULL, p_error_message text DEFAULT NULL, p_correlation_id uuid DEFAULT NULL, p_metadata jsonb DEFAULT '{}')` | → `uuid` | `p_status` must be `started`/`succeeded`/`failed`/`skipped`. Returns the inserted event id — useful for a "recent activity" feed. |

### 3.14 Backup / restore

| Function | Params | Returns | Notes |
| --- | --- | --- | --- |
| `sync_export_account_backup()` | — | `jsonb` | Bundles profiles, addons, plugins, library, watch progress, watched items, settings blobs, home catalog settings, collections, tracker settings into one document (`format: "nuvio_account_backup", version: 1`). **Excludes** auth sessions, linked devices, PIN hashes, tracker tokens, provider credentials, and audit logs. |
| `sync_restore_account_backup(p_backup jsonb, p_mode text DEFAULT 'replace')` | `jsonb` (`{restored_at, mode, counts, sensitive_data_excluded}`) | **Fully destructive** — deletes all existing account data, then restores from the backup. Only `p_mode = 'replace'` is implemented (no merge mode). Validates backup `format`/`version`. |

### 3.15 Misc / platform

| Function | Params | Returns | Notes |
| --- | --- | --- | --- |
| `health_ping()` | — | `boolean` | `anon`. Always `true`; liveness check. |
| `get_avatar_catalog()` | — | `SETOF avatar_catalog` | `anon`. ~40 built-in avatars, ordered by category/sort order. |

## 4. Direct table access via PostgREST

Most tables have RLS policies scoping rows to `auth.uid() = user_id`, so
direct `GET/POST/PATCH/DELETE /rest/v1/<table>` calls are technically safe
for a signed-in user, but the project's own direction — evidenced by
purpose-built RPCs like `sync_patch_profile` and
`sync_push_profile_settings_blob_guarded` — is to prefer the RPC surface
wherever a dedicated `sync_*` function exists (it gets you delta-event
bookkeeping, audit logging, and validation that raw table access skips).

Exceptions worth knowing:

- `avatar_catalog` — world-readable (`FOR SELECT USING (true)`), safe to
  query directly even unauthenticated: `GET /rest/v1/avatar_catalog?is_active=eq.true&order=sort_order`.
- `tv_login_sessions` — table grant exists but RLS is `USING (false)`, i.e.
  **no direct access at all**; must go through the TV-login RPCs.
- `tracker_tv_login_sessions` — read-only if you're the owner
  (`auth.uid() = owner_user_id`); writes require service role (done via the
  `tracker-tv-logins-exchange` edge function).
- `provider_credentials` — has RLS but no table grant to `anon`/`authenticated`,
  so it's unreachable via REST; RPC-only.
- `media_servers`, `device_login_code_attempts` — no table grants for
  `anon`/`authenticated`; RPC-only (`media_servers` holds access tokens).
- `metadata_cache` — shared name/poster cache for `resolve-metadata`; RLS on,
  service-role access only.
- `library_item_events`, `watch_progress_events`, `watched_item_events`,
  `user_activity_events`, `sync_push_audit_logs` — internal delta/audit logs,
  effectively locked down; use the `sync_pull_*_delta` RPCs instead.

## 5. Edge functions

Deno functions under `volumes/functions/`, reached at `/functions/v1/<name>`.
Kong applies no auth at the gateway for these routes — each function
authenticates itself.

| Function | Method(s) | Auth | Request | Response | Purpose |
| --- | --- | --- | --- | --- | --- |
| `health-check` | GET, OPTIONS | none (uses service role internally) | — | `{status, database, latency_ms, timestamp[, error]}` (200 healthy/slow, 503 down) | Liveness/DB probe via `health_ping()`. |
| `delete-account` | POST, OPTIONS | `Authorization: Bearer <user JWT>` | none | `{success: true}` or `{error}` | Verifies the caller, then uses a service-role client to delete the account (`auth.admin.deleteUser`); cascades via DB triggers. |
| `tv-logins-exchange` | POST, OPTIONS | one-time TV login code (no bearer from the caller) | `{code, device_nonce}` | `{access_token, refresh_token, token_type, expires_in}` or `{error}` | Second step of TV sign-in: consumes an approved pairing session and mints a real session for the TV, without the TV ever seeing a password. |
| `tracker-tv-logins-exchange` | POST, OPTIONS | phone's user JWT (must own the pairing session) | `{code, tracker: "mal"\|"anilist"\|"kitsu", access_token, refresh_token?, expires_in?, tracker_user_id?, username?}` | `{ok: true}` or `{error, detail?}` | Phone relays tracker OAuth tokens after completing OAuth, so the TV's poll RPC can pick them up. |
| `resolve-metadata` | POST, OPTIONS | `Authorization: Bearer <user JWT>` | `{items: [{id, type}, ...], profile_id?: number}` | `{items: [{id, type, name: string\|null, poster: string\|null}, ...]}` | Resolves display name/poster for a batch of content ids — `sync_pull_watch_progress`/`sync_pull_watched_items` return only ids, no titles or artwork. Looks in the caller's `library_items`, then a shared `metadata_cache` table, then the profile's enabled addons (whichever advertise a `meta` resource for the item's type), then falls back to Cinemeta. Unresolved items come back with `name`/`poster` as `null` rather than being omitted, so the response array always matches the request 1:1. Newly resolved items are cached in `metadata_cache` for future requests. Added alongside migration `00000000000012`. |

All functions set permissive CORS (`Access-Control-Allow-Origin: *`).

## 5a. Nuvio Mobile compatibility

Nuvio Mobile documents the sync surface it uses in its own
`Docs/SYNC_BACKEND_API.md`. This backend implements all of it. The tables below
map the app's calls to this document and list the behaviours that matter when
building or testing against it. `tests/smoke-mobile-sync.sh` replays the app's
request shapes and runs in CI.

### Conventions the app relies on

- **Parameters** are named `p_*`. Zero-argument RPCs (`sync_pull_profiles`,
  `sync_pull_profile_locks`, `get_avatar_catalog`) are sent with no body.
- **`p_origin_client_id`** is `nuvio-mobile-` plus 32 random characters
  (16-96 characters of `[A-Za-z0-9_-]`) and is also the `p_installation_id`
  for `register_current_device` (client name `Nuvio Mobile`). It is optional on
  every function that accepts it, and `sync_push_plugins` is called without it.
  The app does not filter pulls by it.
- **Platform keys:** the settings blob uses `p_platform: "mobile"`; home catalog
  settings use the shared `home_catalog_shared` key. TV colour normalisation
  applies only to `platform = 'tv'`, so mobile blobs are stored verbatim.
- **Writes:** addons, plugins, provider credentials and media servers are full
  replacements. The settings blob, collections and home catalog settings are
  last-write-wins and stored as given (unknown keys survive). Profile push is an
  upsert and never deletes; deletion uses `sync_delete_profile_data`.
- **Credentials:** the app pushes a snapshot of every provider, empty values
  included, and clears a local key when no row comes back for it. Every row must
  hold exactly `{"api_key": <string>}` (`{"client_id": <string>}` for
  `animeskip`); anything else fails the whole credential sync on the device.
- **Delta feeds:** the app reads the cursor, then the snapshot, then deltas
  after the cursor. Library, watch-progress and watched-item delete events carry
  the identifying key (`content_id`/`content_type`, `progress_key`, or
  `content_id`/`season`/`episode`). Snapshot pulls page with `OFFSET`: library
  500 rows, watched items 900 rows (1-based pages), until a short page.
- **Never return HTTP 401/403 for business errors on sync calls.** The app
  treats them, and a few error texts (a JWT that is invalid or expired, "user"
  with "not found"/"does not exist"/"deleted", or a foreign-key error mentioning
  `auth.users`/`user_id`), as a dead session, signs out and wipes local account
  data. Conflicts use `PT409` (HTTP 409), validation uses `22023`.

### Call map

| Mobile feature | Calls |
| --- | --- |
| Sign-in, device link | GoTrue email/password; `start_device_login_session` (`p_device_type: "mobile"`), `poll_tv_login_session`, `tv-logins-exchange` (§3.2, §5) |
| Profiles and PIN | `sync_pull_profiles`, `sync_push_profiles`, `sync_delete_profile_data`, `verify_profile_pin`, `set_profile_pin`, `clear_profile_pin`, `clear_profile_pin_with_account_password`, `sync_pull_profile_locks` (§3.3) |
| Addons, plugins | `GET /rest/v1/addons`, `GET /rest/v1/plugins` (`profile_id=eq.N&order=sort_order.asc`), `sync_push_addons`, `sync_push_plugins` (§3.7) |
| Settings, credentials | `sync_pull/push_profile_settings_blob` (`mobile`), `sync_pull/push_provider_credentials` (§3.9, §3.11) |
| Library | `sync_pull_library`, `sync_get_library_delta_cursor`, `sync_pull_library_delta`, `sync_push_library_items`, `sync_delete_library_items` (§3.4) |
| Watch progress, watched | `sync_pull_watch_progress` and its delta/cursor, `sync_push_watch_progress`, `sync_delete_watch_progress`; `sync_pull_watched_items` and its delta/cursor, `sync_push_watched_items`, `sync_delete_watched_items` (§3.5, §3.6) |
| Collections, home, servers | `sync_pull/push_collections`, `sync_pull/push_home_catalog_settings` (`home_catalog_shared`), `sync_pull/push_media_servers` (§3.8, §3.10, §3.9a) |
| Device and account | `register_current_device`, `get_avatar_catalog`, `delete-account` |

### Known differences from the hosted service

- **Watch-progress writes are throttled** (matches the hosted backend). An update
  to an existing row is stored only if the position moved by at least 15 s,
  `last_watched` is at least 30 s newer, or it crosses 90 % of the duration. A
  final "stop" scrobble inside those limits is dropped, so a stored resume
  position can lag by up to roughly 15-30 s. Older pushes never move progress
  backwards.
- **Profile backgrounds are not supported** (§7). `sync_pull_profiles` does not
  return `profile_background_id`/`profile_background_url` and push ignores them.
- **Membership and watch-party RPCs are not implemented**
  (`get_my_member_access`, `get_my_membership_overview`,
  `get_member_profile_avatar_catalog`, `get_member_profile_background_catalog`,
  `watch_party_*`). PostgREST answers 404; the app treats that as "no access".
  `/.well-known/nuvio` omits `capabilities.watch_party`, which the app defaults
  to `false`.
- **Device linking needs a `/link` page.** `start_device_login_session` requires
  the redirect URL to contain `/link`, and the app passes `<backend_url>/link`.
  That page is served by the account dashboard behind the proxy, not by this
  repository; `/.well-known/nuvio` advertises `tv_login: true`.
- **Delta event ids are assigned in commit order per account.** Event inserts
  take a per-account advisory lock before drawing the id (migration
  `00000000000016`), so a device that pulls between two concurrent pushes cannot
  move its cursor past an event that has not committed yet. Ids may have gaps.

## 5b. Nuvio TV compatibility

Nuvio TV documents the sync protocol it speaks in `docs/sync.md` of the
`nuvio-tv` repository. That document describes the server partly from inference,
so where it disagrees with this reference, this backend is the source of truth.
`tests/smoke-tv-sync.sh` replays the TV request shapes that changed in migration
`00000000000016` and runs in CI.

### Known differences from the TV sync document

- **Account linking (sync codes) is not implemented.** `generate_sync_code`,
  `get_sync_code`, `claim_sync_code`, `unlink_device`, the `linked_devices` table
  and a linked-device-aware `get_sync_owner()` do not exist. `get_sync_owner()`
  returns the caller's own id. The TV's sync-code and linked-devices screens get
  404s, and a second sign-in cannot read another account's data. Several devices
  signed in to the same account sync normally.
- **`sync_pull_watch_progress` snapshots are capped by `PGRST_DB_MAX_ROWS`**
  (default `1000`, set in `compose.yml` and `.env.example`). The TV's snapshot
  pull sends no `p_limit` and expects every row, but PostgREST truncates RPC
  results at that cap without an error. An account with more than 1000
  watch-progress rows (episodes plus series entries) loses the oldest resume
  entries on the first sync and on the TV's 6-hourly full pull. Raise
  `PGRST_DB_MAX_ROWS` if accounts on this instance hold that many rows. The
  delta feeds and the 900- and 500-row paged pulls for watched items and the
  library are not affected.
- **Watch-progress pushes are filtered** (see §5a for the throttle). A BEFORE
  trigger also rewrites `progress_key` to `<content_id>_s<season>e<episode>` for
  episodes and to `<content_id>` otherwise, so a series-level entry that carries
  a season and episode is stored on the episode's row. The TV drops those
  entries from its pushes whenever the episode entry is at least as fresh.
- **New accounts and profiles are seeded with default addons** that carry a
  `name`, which the TV reads as a user rename.
- **`sync_push_profiles` never deletes profiles** (§3.3), and profile 1 can be
  deleted with `sync_delete_profile_data`.
- **Profile backgrounds, membership and watch-party RPCs are not supported**
  (§5a, §7). The TV treats the missing RPCs as "no access".
- **`poll_tv_login_session` can return `exchanged`** after a successful token
  exchange. The TV never polls past the exchange, and it shows unknown statuses
  as text. An approved session past its expiry still polls as `approved`, and the
  exchange then fails, because the code is consumed before tokens are minted;
  the TV has to start a new login. New-session rate limiting raises HTTP 400
  rather than 429, and `register_current_device` raises 403 when the JWT has no
  matching session; the TV logs and ignores that failure.

## 6. Storage

Buckets (`database/migrations/00000000000002_storage.sql`), both public,
5 MB file size limit:

| Bucket | Allowed MIME types |
| --- | --- |
| `avatars` | `image/png`, `image/jpeg`, `image/webp` |
| `covers` | any |

URL patterns:

- Public read: `GET <backend_url>/storage/v1/object/public/avatars/<path>`
  and `.../public/covers/<path>`.
- Authenticated upload: `POST <backend_url>/storage/v1/object/<bucket>/<path>`
  with `Authorization: Bearer <user JWT>` (no `apikey` required at the
  gateway for storage routes).

The `avatar_catalog` table (world-readable, see §4) lists built-in avatar
options with `id, display_name, storage_path, category, sort_order,
is_active, bg_color` — use `storage_path` to build the public avatars URL, or
let the user supply a custom `avatar_url` via `sync_patch_profile`.

## 7. Known self-hosted deviations

- **Profile background images are not supported on self-hosted.**
  `sync_patch_profile` accepts `p_profile_background_id`/
  `p_profile_background_url` parameters for parity with the hosted product,
  but setting either one always raises
  `0A000 Profile backgrounds are not available on self-hosted Nuvio`. Don't
  build UI that lets a user set a profile background against this backend.
- `sync_pull_watched_items` mirrors the hosted backend's RPC signature
  exactly and returns raw per-episode rows (not grouped) — this is
  intentional for client-sync fidelity. Use
  `sync_pull_watched_items_grouped` (self-hosted-only, added in migration
  `00000000000011`) for a grouped watch-history UI instead.
- `sync_pull_watch_progress` and `sync_pull_watched_items` only return
  `content_id`/`content_type` (and season/episode), not a display name or
  poster — the hosted dashboard resolved those in its own Next.js server
  route. Self-hosted has no equivalent server route, so use the
  `resolve-metadata` edge function (§5, added alongside migration
  `00000000000012`) to look up names/posters for a batch of ids instead of
  querying addons directly from the browser (which runs into per-addon CORS
  restrictions and issues many requests).
