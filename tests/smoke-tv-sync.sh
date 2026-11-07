#!/bin/sh

# Replays the sync calls Nuvio TV makes that migration 00000000000016 changed:
# profile setup copy, repeated addon and plugin URLs, delete tombstones that
# survive a profile deletion, and delta event ordering. Request shapes follow
# the TV client (named p_ parameters, explicit nulls, and a nuvio-tv-<32 chars>
# origin id).

set -eu

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

env_value() {
    grep "^$1=" .env | head -n 1 | cut -d= -f2-
}

query() {
    docker compose exec -T db psql -U supabase_admin -d postgres -Atc "$1"
}

rpc() {
    function_name=$1
    body=$2
    curl --fail-with-body -sS \
        -X POST \
        -H "apikey: $anon_key" \
        -H "Authorization: Bearer $access_token" \
        -H "Content-Type: application/json" \
        --data "$body" \
        "$public_url/rest/v1/rpc/$function_name"
}

# Prints the HTTP status instead of failing on an error response.
rpc_status() {
    function_name=$1
    body=$2
    curl -sS -o /dev/null -w '%{http_code}' \
        -X POST \
        -H "apikey: $anon_key" \
        -H "Authorization: Bearer $access_token" \
        -H "Content-Type: application/json" \
        --data "$body" \
        "$public_url/rest/v1/rpc/$function_name"
}

table_get() {
    curl --fail-with-body -sS \
        -H "apikey: $anon_key" \
        -H "Authorization: Bearer $access_token" \
        "$public_url/rest/v1/$1"
}

email="tv-smoke-$(date -u +%s)@example.invalid"
password="Tv-$(openssl rand -hex 12)"
origin="nuvio-tv-$(openssl rand -hex 16)"
public_url=$(env_value SUPABASE_PUBLIC_URL)
anon_key=$(env_value ANON_KEY)
signup_response=$(mktemp)
user_id=""

cleanup() {
    rm -f "$signup_response"
    if [ -n "$user_id" ]; then
        query "delete from auth.users where id = '$user_id'" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

curl --fail-with-body -sS \
    -X POST \
    -H "apikey: $anon_key" \
    -H "Authorization: Bearer $anon_key" \
    -H "Content-Type: application/json" \
    --data "{\"email\":\"$email\",\"password\":\"$password\"}" \
    "$public_url/auth/v1/signup" > "$signup_response"

access_token=$(jq -er '.access_token' "$signup_response")
user_id=$(jq -er '.user.id' "$signup_response")

# Profiles: the TV always sends every key, with explicit nulls.
rpc sync_push_profiles "{\"p_client_max_profiles\":6,\"p_profiles\":[{\"profile_index\":1,\"name\":\"TV One\",\"avatar_color_hex\":\"#1E88E5\",\"uses_primary_addons\":false,\"uses_primary_plugins\":false,\"avatar_id\":null,\"avatar_url\":null,\"profile_background_id\":null,\"profile_background_url\":null},{\"profile_index\":2,\"name\":\"TV Two\",\"avatar_color_hex\":\"#E53935\",\"uses_primary_addons\":false,\"uses_primary_plugins\":false,\"avatar_id\":null,\"avatar_url\":null,\"profile_background_id\":null,\"profile_background_url\":null}],\"p_origin_client_id\":\"$origin\"}" >/dev/null
rpc sync_pull_profiles '{}' | jq -e '[.[] | select(.profile_index == 1 or .profile_index == 2)] | length == 2' >/dev/null
echo "OK  TV profiles"

# sync_copy_profile_setup: the TV pushes the source settings, then copies them.
copy_body() {
    # $1 copy credentials, $2 replace credentials
    printf '{"p_source_profile_id":1,"p_target_profile_id":2,"p_copy_tv":true,"p_copy_mobile":false,"p_copy_desktop":false,"p_copy_provider_credentials":%s,"p_replace_provider_credentials":%s,"p_origin_client_id":"%s"}' "$1" "$2" "$origin"
}

tv_blob='{"version":1,"features":{"theme_settings":{"selected_theme":{"type":"string","value":"OCEAN"}},"player_settings":{"subtitle_text_color":{"type":"int","value":-1},"preferred_audio_language":{"type":"string","value":"eng"}},"layout_settings":{"hero_section_enabled":{"type":"boolean","value":false}}}}'
rpc sync_push_profile_settings_blob "{\"p_profile_id\":1,\"p_settings_json\":$tv_blob,\"p_platform\":\"tv\",\"p_origin_client_id\":\"$origin\"}" >/dev/null

# No credentials exist for the source profile yet.
rpc sync_copy_profile_setup "$(copy_body true false)" | jq -e '
    length == 1
    and .[0].source_profile_id == 1
    and .[0].target_profile_id == 2
    and .[0].tv_status == "copied"
    and .[0].provider_credentials_status == "source_missing"
' >/dev/null
rpc sync_pull_profile_settings_blob '{"p_profile_id":2,"p_platform":"tv"}' | jq -e --argjson blob "$tv_blob" '.[0].settings_json == $blob' >/dev/null
rpc sync_copy_profile_setup "$(copy_body false false)" | jq -e '.[0].tv_status == "unchanged" and .[0].provider_credentials_status == "unchanged"' >/dev/null

credentials='[{"provider":"debrid:torbox","credential_json":{"api_key":"tb-key"}},{"provider":"debrid:premiumize","credential_json":{"api_key":""}},{"provider":"debrid:realdebrid","credential_json":{"api_key":""}},{"provider":"mdblist","credential_json":{"api_key":"md-key"}},{"provider":"animeskip","credential_json":{"client_id":""}}]'
rpc sync_push_provider_credentials "{\"p_profile_id\":1,\"p_credentials\":$credentials,\"p_origin_client_id\":\"$origin\"}" >/dev/null
rpc sync_copy_profile_setup "$(copy_body true false)" | jq -e '.[0].tv_status == "unchanged" and .[0].provider_credentials_status == "copied"' >/dev/null
rpc sync_pull_provider_credentials '{"p_profile_id":2}' | jq -e 'length == 5 and ([.[] | select(.provider == "debrid:torbox")][0].credential_json.api_key == "tb-key")' >/dev/null
rpc sync_copy_profile_setup "$(copy_body true false)" | jq -e '.[0].provider_credentials_status == "unchanged"' >/dev/null

# A different value on the target is kept unless replacement is requested.
rpc sync_push_provider_credentials "{\"p_profile_id\":2,\"p_credentials\":[{\"provider\":\"mdblist\",\"credential_json\":{\"api_key\":\"other\"}}],\"p_origin_client_id\":\"$origin\"}" >/dev/null
rpc sync_copy_profile_setup "$(copy_body true false)" | jq -e '.[0].provider_credentials_status == "kept_existing"' >/dev/null
rpc sync_pull_provider_credentials '{"p_profile_id":2}' | jq -e '[.[] | select(.provider == "mdblist")][0].credential_json.api_key == "other"' >/dev/null
rpc sync_copy_profile_setup "$(copy_body true true)" | jq -e '.[0].provider_credentials_status == "copied"' >/dev/null
rpc sync_pull_provider_credentials '{"p_profile_id":2}' | jq -e '[.[] | select(.provider == "mdblist")][0].credential_json.api_key == "md-key"' >/dev/null

# Same profile, and a profile that does not exist, are rejected.
[ "$(rpc_status sync_copy_profile_setup "{\"p_source_profile_id\":1,\"p_target_profile_id\":1,\"p_copy_tv\":true,\"p_origin_client_id\":\"$origin\"}")" = "400" ] || {
    echo "Copying a profile onto itself should be rejected" >&2
    exit 1
}
[ "$(rpc_status sync_copy_profile_setup "{\"p_source_profile_id\":1,\"p_target_profile_id\":5,\"p_copy_tv\":true,\"p_origin_client_id\":\"$origin\"}")" = "400" ] || {
    echo "Copying to a missing profile should be rejected" >&2
    exit 1
}
echo "OK  TV profile setup copy"

# Addons and plugins: a repeated URL keeps the last entry instead of failing.
rpc sync_push_addons "{\"p_profile_id\":1,\"p_addons\":[{\"url\":\"https://tv-a.example.invalid\",\"sort_order\":0,\"enabled\":true,\"name\":\"First\"},{\"url\":\"https://tv-b.example.invalid\",\"sort_order\":1,\"enabled\":false},{\"url\":\"https://tv-a.example.invalid\",\"sort_order\":2,\"enabled\":true,\"name\":\"Last\"}],\"p_origin_client_id\":\"$origin\"}" >/dev/null
table_get 'addons?select=*&profile_id=eq.1&order=sort_order.asc' | jq -e 'length == 2 and .[0].url == "https://tv-b.example.invalid" and .[0].enabled == false and .[1].url == "https://tv-a.example.invalid" and .[1].name == "Last"' >/dev/null
rpc sync_push_plugins "{\"p_profile_id\":1,\"p_plugins\":[{\"url\":\"https://tv-repo.example.invalid/manifest.json\",\"name\":\"Old\",\"enabled\":true,\"sort_order\":0,\"repo_type\":\"NUVIO_JS\"},{\"url\":\"https://tv-repo.example.invalid/manifest.json\",\"name\":\"New\",\"enabled\":false,\"sort_order\":0,\"repo_type\":\"NUVIO_JS\"}],\"p_origin_client_id\":\"$origin\"}" >/dev/null
table_get 'plugins?select=*&profile_id=eq.1' | jq -e 'length == 1 and .[0].name == "New" and .[0].enabled == false and .[0].repo_type == "NUVIO_JS"' >/dev/null
# An empty list still clears the profile (the TV only pushes its full list).
rpc sync_push_addons "{\"p_profile_id\":1,\"p_addons\":[],\"p_origin_client_id\":\"$origin\"}" >/dev/null
table_get 'addons?select=*&profile_id=eq.1' | jq -e 'length == 0' >/dev/null
echo "OK  TV addons and plugins with repeated URLs"

# Delete tombstones survive a profile deletion. A second device holding a
# cursor from before the deletion has to see the deletes.
now_ms=$(( $(date -u +%s) * 1000 ))
progress_cursor=$(rpc sync_get_watch_progress_delta_cursor '{"p_profile_id":2}')
watched_cursor=$(rpc sync_get_watched_items_delta_cursor '{"p_profile_id":2}')
library_cursor=$(rpc sync_get_library_delta_cursor '{"p_profile_id":2}')

rpc sync_push_watch_progress "{\"p_profile_id\":2,\"p_entries\":[{\"content_id\":\"tt-tv-show\",\"content_type\":\"series\",\"video_id\":\"tt-tv-show:1:1\",\"season\":1,\"episode\":1,\"position\":1000,\"duration\":7200000,\"last_watched\":$now_ms,\"progress_key\":\"tt-tv-show_s1e1\"}],\"p_origin_client_id\":\"$origin\"}" >/dev/null
rpc sync_push_watched_items "{\"p_profile_id\":2,\"p_items\":[{\"content_id\":\"tt-tv-film\",\"content_type\":\"movie\",\"title\":\"TV Film\",\"season\":null,\"episode\":null,\"watched_at\":$now_ms}],\"p_origin_client_id\":\"$origin\"}" >/dev/null
rpc sync_push_library_items "{\"p_profile_id\":2,\"p_items\":[{\"content_id\":\"tt-tv-lib\",\"content_type\":\"movie\",\"name\":\"TV Library\",\"poster\":null,\"poster_shape\":\"POSTER\",\"background\":null,\"description\":null,\"release_info\":null,\"imdb_rating\":null,\"genres\":[],\"addon_base_url\":null,\"added_at\":$now_ms}],\"p_origin_client_id\":\"$origin\"}" >/dev/null

rpc sync_pull_watch_progress_delta "{\"p_profile_id\":2,\"p_since_event_id\":$progress_cursor,\"p_limit\":900}" | jq -e '[.[] | select(.operation == "upsert" and .progress_key == "tt-tv-show_s1e1")] | length == 1' >/dev/null

rpc sync_delete_profile_data "{\"p_profile_id\":2,\"p_origin_client_id\":\"$origin\"}" >/dev/null
rpc sync_pull_profiles '{}' | jq -e '[.[] | select(.profile_index == 2)] | length == 0' >/dev/null
rpc sync_pull_watch_progress '{"p_profile_id":2}' | jq -e 'length == 0' >/dev/null

rpc sync_pull_watch_progress_delta "{\"p_profile_id\":2,\"p_since_event_id\":$progress_cursor,\"p_limit\":900}" | jq -e '
    ([.[] | select(.operation == "delete" and .progress_key == "tt-tv-show_s1e1" and .content_id == "tt-tv-show" and .content_type == "series")] | length == 1)
    and ([.[] | .event_id] | . == sort)
' >/dev/null
rpc sync_pull_watched_items_delta "{\"p_profile_id\":2,\"p_since_event_id\":$watched_cursor,\"p_limit\":900}" | jq -e '[.[] | select(.operation == "delete" and .content_id == "tt-tv-film")] | length == 1' >/dev/null
rpc sync_pull_library_delta "{\"p_profile_id\":2,\"p_since_event_id\":$library_cursor,\"p_limit\":500}" | jq -e '[.[] | select(.operation == "delete" and .content_id == "tt-tv-lib" and .content_type == "movie")] | length == 1' >/dev/null

# The cursor does not fall back below what other devices already hold.
after_cursor=$(rpc sync_get_watch_progress_delta_cursor '{"p_profile_id":2}')
[ "$after_cursor" -gt "$progress_cursor" ] || {
    echo "Profile deletion lowered the watch-progress cursor ($progress_cursor -> $after_cursor)" >&2
    exit 1
}
echo "OK  TV profile delete keeps delta tombstones"

# Delta event ordering: an event insert waits for an earlier uncommitted one
# from the same account, so ids become visible in id order. The first session
# holds its transaction open for three seconds.
holder_log=$(mktemp)
(
    query "begin; insert into public.watched_item_events (user_id, profile_id, operation, content_id, content_type, title, watched_at) values ('$user_id', 1, 'upsert', 'tt-order-first', 'movie', '', 1); select pg_sleep(3); commit;" > "$holder_log" 2>&1
) &
holder_pid=$!
sleep 1
started=$(date -u +%s)
query "insert into public.watched_item_events (user_id, profile_id, operation, content_id, content_type, title, watched_at) values ('$user_id', 1, 'upsert', 'tt-order-second', 'movie', '', 2)" >/dev/null
elapsed=$(( $(date -u +%s) - started ))
wait "$holder_pid"
rm -f "$holder_log"
[ "$elapsed" -ge 1 ] || {
    echo "Second event insert did not wait for the first transaction (waited ${elapsed}s)" >&2
    exit 1
}
[ "$(query "select (select event_id from public.watched_item_events where user_id = '$user_id' and content_id = 'tt-order-first') < (select event_id from public.watched_item_events where user_id = '$user_id' and content_id = 'tt-order-second')")" = "t" ] || {
    echo "Event ids were not assigned in commit order" >&2
    exit 1
}
echo "OK  TV delta event ordering"
