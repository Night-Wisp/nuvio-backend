#!/bin/sh

# Replays the sync calls Nuvio Mobile makes, using the request shapes from its
# Docs/SYNC_BACKEND_API.md (named p_ parameters, explicit nulls, zero-argument
# calls without a body, p_platform "mobile" / "home_catalog_shared", and a
# nuvio-mobile-<32 chars> origin id), and asserts the responses it relies on.

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

# The app calls zero-argument RPCs without sending a parameter object.
rpc_no_body() {
    function_name=$1
    curl --fail-with-body -sS \
        -X POST \
        -H "apikey: $anon_key" \
        -H "Authorization: Bearer $access_token" \
        -H "Content-Type: application/json" \
        "$public_url/rest/v1/rpc/$function_name"
}

rpc_anon() {
    function_name=$1
    body=$2
    curl --fail-with-body -sS \
        -X POST \
        -H "apikey: $anon_key" \
        -H "Authorization: Bearer $anon_key" \
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

email="mobile-smoke-$(date -u +%s)@example.invalid"
password="Mobile-$(openssl rand -hex 12)"
origin="nuvio-mobile-$(openssl rand -hex 16)"
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

# Auxiliary: device registration uses the origin id as the installation id.
registered=$(rpc register_current_device "{\"p_installation_id\":\"$origin\",\"p_client_name\":\"Nuvio Mobile\",\"p_client_version\":\"smoke\",\"p_platform\":\"android\",\"p_device_name\":\"Mobile Smoke\"}")
printf '%s' "$registered" | jq -e '. == true' >/dev/null
echo "OK  mobile device registration"

# Profiles: explicit nulls, full list, then pull as the source of truth.
rpc sync_push_profiles "{\"p_client_max_profiles\":6,\"p_profiles\":[{\"profile_index\":1,\"name\":\"Mobile One\",\"avatar_color_hex\":\"#1E88E5\",\"uses_primary_addons\":false,\"uses_primary_plugins\":false,\"avatar_id\":null,\"avatar_url\":null,\"profile_background_id\":null,\"profile_background_url\":null},{\"profile_index\":2,\"name\":\"Mobile Two\",\"avatar_color_hex\":\"#E53935\",\"uses_primary_addons\":true,\"uses_primary_plugins\":true,\"avatar_id\":null,\"avatar_url\":null,\"profile_background_id\":null,\"profile_background_url\":null}],\"p_origin_client_id\":\"$origin\"}" >/dev/null
profiles=$(rpc_no_body sync_pull_profiles)
printf '%s' "$profiles" | jq -e '[.[] | select((.profile_index == 1 and .name == "Mobile One") or (.profile_index == 2 and .name == "Mobile Two" and .uses_primary_addons == true))] | length == 2' >/dev/null
rpc_no_body sync_pull_profile_locks | jq -e 'type == "array"' >/dev/null
rpc verify_profile_pin '{"p_profile_id":1,"p_pin":"0000"}' | jq -e '(if type == "array" then .[0] else . end) | .unlocked == true' >/dev/null
echo "OK  mobile profiles"

# Settings blob: "mobile" platform, last-write-wins, string payloads and
# unknown keys stored verbatim, and the TV colour normalisation left alone.
blob_one='{"version":4,"features":{"theme_settings":{"selected_theme":{"type":"string","value":"WHITE"}},"poster_card_style_settings_payload":"{\"widthDp\":126,\"heightDp\":189}","custom_poster_enabled_screens":"","player_settings":{"subtitle_text_color":{"type":"string","value":"#FFFFFF"},"next_episode_threshold_percent_v2":{"type":"float","value":99}},"notifications_settings":{"episode_release_alerts_enabled":false},"future_feature":{"keep":true}}}'
rpc sync_push_profile_settings_blob "{\"p_profile_id\":1,\"p_platform\":\"mobile\",\"p_settings_json\":$blob_one,\"p_origin_client_id\":\"$origin\"}" >/dev/null
settings=$(rpc sync_pull_profile_settings_blob '{"p_profile_id":1,"p_platform":"mobile"}')
printf '%s' "$settings" | jq -e '
    .[0].settings_json.features.player_settings.subtitle_text_color == {"type":"string","value":"#FFFFFF"}
    and .[0].settings_json.features.poster_card_style_settings_payload == "{\"widthDp\":126,\"heightDp\":189}"
    and .[0].settings_json.features.future_feature.keep == true
    and .[0].settings_json.features.custom_poster_enabled_screens == ""
' >/dev/null
rpc sync_pull_profile_settings_blob '{"p_profile_id":1,"p_platform":"tv"}' | jq -e 'length == 0' >/dev/null
blob_two='{"version":4,"features":{"theme_settings":{"selected_theme":{"type":"string","value":"CUSTOM"}}}}'
rpc sync_push_profile_settings_blob "{\"p_profile_id\":1,\"p_platform\":\"mobile\",\"p_settings_json\":$blob_two,\"p_origin_client_id\":\"$origin\"}" >/dev/null
rpc sync_pull_profile_settings_blob '{"p_profile_id":1,"p_platform":"mobile"}' | jq -e '.[0].settings_json == {"version":4,"features":{"theme_settings":{"selected_theme":{"type":"string","value":"CUSTOM"}}}}' >/dev/null
echo "OK  mobile settings blob"

# Provider credentials: the app pushes a snapshot of every provider, including
# empty values, and clears a local key when no row comes back for it.
credentials='[{"provider":"debrid:torbox","credential_json":{"api_key":"tb-key"}},{"provider":"debrid:premiumize","credential_json":{"api_key":""}},{"provider":"debrid:realdebrid","credential_json":{"api_key":""}},{"provider":"tmdb","credential_json":{"api_key":"tmdb-key"}},{"provider":"mdblist","credential_json":{"api_key":""}},{"provider":"animeskip","credential_json":{"client_id":"as-client"}},{"provider":"introdb","credential_json":{"api_key":""}}]'
rpc sync_push_provider_credentials "{\"p_profile_id\":1,\"p_credentials\":$credentials,\"p_origin_client_id\":\"$origin\"}" >/dev/null
pulled_credentials=$(rpc sync_pull_provider_credentials '{"p_profile_id":1}')
printf '%s' "$pulled_credentials" | jq -e '
    length == 7
    and ([.[] | select(.provider == "tmdb")][0].credential_json.api_key == "tmdb-key")
    and ([.[] | select(.provider == "debrid:premiumize")][0].credential_json.api_key == "")
    and ([.[] | select(.provider == "animeskip")][0].credential_json.client_id == "as-client")
    and all(.[]; (.credential_json | to_entries | length == 1) and (.credential_json | to_entries[0].value | type == "string"))
' >/dev/null
echo "OK  mobile provider credentials"

# Addons and plugins: full ordered list replace, read back through PostgREST.
rpc sync_push_addons "{\"p_profile_id\":1,\"p_addons\":[{\"url\":\"https://addon-a.example.invalid/manifest.json\",\"name\":\"\",\"enabled\":true,\"sort_order\":0},{\"url\":\"https://addon-b.example.invalid/manifest.json\",\"name\":\"Addon B\",\"enabled\":false,\"sort_order\":1}],\"p_origin_client_id\":\"$origin\"}" >/dev/null
table_get 'addons?select=*&profile_id=eq.1&order=sort_order.asc' | jq -e 'length == 2 and .[0].url == "https://addon-a.example.invalid/manifest.json" and .[1].enabled == false and .[1].name == "Addon B"' >/dev/null
rpc sync_push_addons "{\"p_profile_id\":1,\"p_addons\":[{\"url\":\"https://addon-b.example.invalid/manifest.json\",\"name\":\"Addon B\",\"enabled\":true,\"sort_order\":0}],\"p_origin_client_id\":\"$origin\"}" >/dev/null
table_get 'addons?select=*&profile_id=eq.1&order=sort_order.asc' | jq -e 'length == 1 and .[0].url == "https://addon-b.example.invalid/manifest.json"' >/dev/null
# sync_push_plugins is called without p_origin_client_id.
rpc sync_push_plugins '{"p_profile_id":1,"p_plugins":[{"url":"https://repo.example.invalid/manifest.json","name":"Repo","enabled":true,"sort_order":0}]}' >/dev/null
table_get 'plugins?select=*&profile_id=eq.1&order=sort_order.asc' | jq -e 'length == 1 and .[0].url == "https://repo.example.invalid/manifest.json" and .[0].enabled == true' >/dev/null
echo "OK  mobile addons and plugins"

# Library: snapshot, cursor, delta and delete events.
library_cursor=$(rpc sync_get_library_delta_cursor '{"p_profile_id":1}')
printf '%s' "$library_cursor" | jq -e 'type == "number"' >/dev/null
library_items='[{"content_id":"tt-mobile-lib-1","content_type":"movie","name":"Mobile One","poster":"https://example.invalid/1.jpg","poster_shape":"POSTER","background":null,"logo":"https://example.invalid/1-logo.png","description":null,"release_info":"2026","imdb_rating":8.5,"genres":["Drama"],"addon_base_url":null,"added_at":1760000000000},{"content_id":"tt-mobile-lib-2","content_type":"series","name":"Mobile Two","poster":null,"poster_shape":"LANDSCAPE","background":null,"logo":null,"description":null,"release_info":null,"imdb_rating":null,"genres":[],"addon_base_url":null,"added_at":1760000000000},{"content_id":"tt-mobile-lib-3","content_type":"movie","name":"Mobile Three","poster":null,"poster_shape":"POSTER","background":null,"logo":null,"description":null,"release_info":null,"imdb_rating":null,"genres":[],"addon_base_url":null,"added_at":1760000000000}]'
rpc sync_push_library_items "{\"p_profile_id\":1,\"p_items\":$library_items,\"p_origin_client_id\":\"$origin\"}" >/dev/null
rpc sync_pull_library '{"p_profile_id":1,"p_limit":500,"p_offset":0}' | jq -e '[.[] | select(.content_id | startswith("tt-mobile-lib-"))] | length == 3' >/dev/null
rpc sync_pull_library_delta "{\"p_profile_id\":1,\"p_since_event_id\":$library_cursor,\"p_limit\":500}" | jq -e '[.[] | select(.operation == "upsert" and (.content_id | startswith("tt-mobile-lib-")))] | length == 3 and all(.[]; .event_id > 0)' >/dev/null

# Items with the same added_at must page without repeats or gaps.
library_total=$(query "select count(*) from public.library_items where user_id = '$user_id' and profile_id = 1")
library_page_ids=""
offset=0
while [ "$offset" -lt "$library_total" ]; do
    page=$(rpc sync_pull_library "{\"p_profile_id\":1,\"p_limit\":1,\"p_offset\":$offset}")
    library_page_ids="$library_page_ids $(printf '%s' "$page" | jq -r '.[].content_id')"
    offset=$((offset + 1))
done
library_unique=$(printf '%s\n' $library_page_ids | sort -u | wc -l | tr -d ' ')
[ "$library_unique" = "$library_total" ] || {
    echo "Library paging returned $library_unique unique items of $library_total" >&2
    exit 1
}

rpc sync_delete_library_items "{\"p_profile_id\":1,\"p_keys\":[{\"content_id\":\"tt-mobile-lib-1\",\"content_type\":\"movie\"}],\"p_origin_client_id\":\"$origin\"}" >/dev/null
rpc sync_pull_library_delta "{\"p_profile_id\":1,\"p_since_event_id\":$library_cursor,\"p_limit\":500}" | jq -e '[.[] | select(.operation == "delete" and .content_id == "tt-mobile-lib-1" and .content_type == "movie")] | length == 1' >/dev/null
echo "OK  mobile library sync and stable paging"

# Watch progress: one scrobble per call, upsert by progress_key, delete by key.
progress_cursor=$(rpc sync_get_watch_progress_delta_cursor '{"p_profile_id":1}')
printf '%s' "$progress_cursor" | jq -e 'type == "number"' >/dev/null
rpc sync_push_watch_progress "{\"p_profile_id\":1,\"p_entries\":[{\"content_id\":\"tt-mobile-show\",\"content_type\":\"series\",\"video_id\":\"tt-mobile-show:1:1\",\"season\":1,\"episode\":1,\"position\":1234567,\"duration\":3600000,\"last_watched\":1760000000000,\"progress_key\":\"tt-mobile-show_s1e1\"}],\"p_origin_client_id\":\"$origin\"}" >/dev/null
rpc sync_push_watch_progress "{\"p_profile_id\":1,\"p_entries\":[{\"content_id\":\"tt-mobile-movie\",\"content_type\":\"movie\",\"video_id\":\"tt-mobile-movie\",\"season\":null,\"episode\":null,\"position\":600000,\"duration\":7200000,\"last_watched\":1760000001000,\"progress_key\":\"tt-mobile-movie\"}],\"p_origin_client_id\":\"$origin\"}" >/dev/null
rpc sync_pull_watch_progress '{"p_profile_id":1}' | jq -e '
    ([.[] | select(.progress_key == "tt-mobile-show_s1e1" and .position == 1234567 and .last_watched == 1760000000000 and .season == 1)] | length == 1)
    and ([.[] | select(.progress_key == "tt-mobile-movie" and .season == null)] | length == 1)
' >/dev/null
rpc sync_pull_watch_progress_delta "{\"p_profile_id\":1,\"p_since_event_id\":$progress_cursor,\"p_limit\":900}" | jq -e '[.[] | select(.operation == "upsert" and .progress_key == "tt-mobile-show_s1e1")] | length == 1' >/dev/null
rpc sync_delete_watch_progress "{\"p_profile_id\":1,\"p_keys\":[\"tt-mobile-show_s1e1\"],\"p_origin_client_id\":\"$origin\"}" >/dev/null
rpc sync_pull_watch_progress_delta "{\"p_profile_id\":1,\"p_since_event_id\":$progress_cursor,\"p_limit\":900}" | jq -e '[.[] | select(.operation == "delete" and .progress_key == "tt-mobile-show_s1e1")] | length == 1' >/dev/null
echo "OK  mobile watch progress"

# Watched items: 1-based pages, delete keys without content_type.
watched_cursor=$(rpc sync_get_watched_items_delta_cursor '{"p_profile_id":1}')
printf '%s' "$watched_cursor" | jq -e 'type == "number"' >/dev/null
rpc sync_push_watched_items "{\"p_profile_id\":1,\"p_items\":[{\"content_id\":\"tt-mobile-show\",\"content_type\":\"series\",\"title\":\"Mobile Show\",\"season\":1,\"episode\":1,\"watched_at\":1760000005000},{\"content_id\":\"tt-mobile-show\",\"content_type\":\"series\",\"title\":\"Mobile Show\",\"season\":1,\"episode\":2,\"watched_at\":1760000005000},{\"content_id\":\"tt-mobile-show\",\"content_type\":\"series\",\"title\":\"Mobile Show\",\"season\":1,\"episode\":3,\"watched_at\":1760000005000},{\"content_id\":\"tt-mobile-film\",\"content_type\":\"movie\",\"title\":\"Mobile Film\",\"season\":null,\"episode\":null,\"watched_at\":1760000005000}],\"p_origin_client_id\":\"$origin\"}" >/dev/null
watched_total=$(query "select count(*) from public.watched_items where user_id = '$user_id' and profile_id = 1")
watched_page_keys=""
page_number=1
while [ "$page_number" -le "$watched_total" ]; do
    page=$(rpc sync_pull_watched_items "{\"p_profile_id\":1,\"p_page\":$page_number,\"p_page_size\":1}")
    watched_page_keys="$watched_page_keys $(printf '%s' "$page" | jq -r '.[] | "\(.content_id):\(.season):\(.episode)"')"
    page_number=$((page_number + 1))
done
watched_unique=$(printf '%s\n' $watched_page_keys | sort -u | wc -l | tr -d ' ')
[ "$watched_unique" = "$watched_total" ] || {
    echo "Watched paging returned $watched_unique unique items of $watched_total" >&2
    exit 1
}
rpc sync_pull_watched_items_delta "{\"p_profile_id\":1,\"p_since_event_id\":$watched_cursor,\"p_limit\":900}" | jq -e '[.[] | select(.operation == "upsert" and .content_id == "tt-mobile-show")] | length >= 3' >/dev/null
rpc sync_delete_watched_items "{\"p_profile_id\":1,\"p_keys\":[{\"content_id\":\"tt-mobile-show\",\"season\":1,\"episode\":2},{\"content_id\":\"tt-mobile-film\",\"season\":null,\"episode\":null}],\"p_origin_client_id\":\"$origin\"}" >/dev/null
rpc sync_pull_watched_items_delta "{\"p_profile_id\":1,\"p_since_event_id\":$watched_cursor,\"p_limit\":900}" | jq -e '
    ([.[] | select(.operation == "delete" and .content_id == "tt-mobile-show" and .season == 1 and .episode == 2)] | length == 1)
    and ([.[] | select(.operation == "delete" and .content_id == "tt-mobile-film")] | length == 1)
' >/dev/null
echo "OK  mobile watched items and stable paging"

# Collections and home catalog settings are stored verbatim, unknown keys included.
rpc sync_push_collections "{\"p_profile_id\":1,\"p_collections_json\":[{\"id\":\"c1\",\"title\":\"Mobile\",\"folders\":[],\"unknownKey\":{\"a\":1}}],\"p_origin_client_id\":\"$origin\"}" >/dev/null
rpc sync_pull_collections '{"p_profile_id":1}' | jq -e '.[0].collections_json[0].unknownKey.a == 1 and .[0].collections_json[0].id == "c1"' >/dev/null
rpc sync_push_home_catalog_settings "{\"p_profile_id\":1,\"p_platform\":\"home_catalog_shared\",\"p_settings_json\":{\"show_catalog_type\":true,\"hide_unreleased_content\":false,\"items\":[],\"other_platform_key\":\"keep\"},\"p_origin_client_id\":\"$origin\"}" >/dev/null
rpc sync_pull_home_catalog_settings '{"p_profile_id":1,"p_platform":"home_catalog_shared"}' | jq -e '.[0].settings_json.other_platform_key == "keep" and .[0].settings_json.show_catalog_type == true' >/dev/null
echo "OK  mobile collections and home catalog"

# Media servers: import_watch_state is an explicit null in the app's payload.
rpc sync_push_media_servers "{\"p_profile_id\":1,\"p_servers\":[{\"id\":\"mobile-local-id\",\"provider_id\":\"jellyfin\",\"name\":\"Home\",\"address\":\"https://jellyfin.example.invalid\",\"remote_server_id\":\"remote-server\",\"remote_user_id\":\"remote-user\",\"user_name\":\"mobile\",\"token\":\"mobile-token\",\"libraries\":[{\"id\":\"lib-1\",\"name\":\"Movies\",\"kind\":\"movie\",\"selected\":true}],\"enabled\":true,\"use_catalog_metadata\":false,\"import_watch_state\":null}],\"p_origin_client_id\":\"$origin\"}" >/dev/null
rpc sync_pull_media_servers '{"p_profile_id":1}' | jq -e '.[0].servers_json[0].id == "mobile-local-id" and .[0].servers_json[0].libraries[0].kind == "movie"' >/dev/null
echo "OK  mobile media servers"

# Device-link login as the device: start, poll, approve from a signed-in
# session, then exchange for a session.
device_nonce="mobile-smoke-nonce-$(openssl rand -hex 8)"
device_start=$(rpc_anon start_device_login_session "{\"p_device_nonce\":\"$device_nonce\",\"p_redirect_base_url\":\"$public_url/link\",\"p_device_name\":\"Mobile Smoke\",\"p_device_type\":\"mobile\"}")
device_code=$(printf '%s' "$device_start" | jq -er '.[0].device_code')
device_user_code=$(printf '%s' "$device_start" | jq -er '.[0].user_code')
printf '%s' "$device_start" | jq -e '.[0].verification_uri_complete | type == "string" and length > 0' >/dev/null
rpc_anon poll_tv_login_session "{\"p_code\":\"$device_code\",\"p_device_nonce\":\"$device_nonce\"}" | jq -e '.[0].status == "pending"' >/dev/null
rpc approve_device_login_session "{\"p_user_code\":\"$device_user_code\"}" | jq -e '.[0].success == true' >/dev/null
rpc_anon poll_tv_login_session "{\"p_code\":\"$device_code\",\"p_device_nonce\":\"$device_nonce\"}" | jq -e '.[0].status == "approved"' >/dev/null
curl --fail-with-body -sS \
    -X POST \
    -H "apikey: $anon_key" \
    -H "Content-Type: application/json" \
    --data "{\"code\":\"$device_code\",\"device_nonce\":\"$device_nonce\"}" \
    "$public_url/functions/v1/tv-logins-exchange" | jq -e '.access_token | type == "string" and length > 20' >/dev/null
echo "OK  mobile device-link login"

# Profile deletion removes the profile and its data.
rpc sync_delete_profile_data "{\"p_profile_id\":2,\"p_origin_client_id\":\"$origin\"}" >/dev/null
rpc_no_body sync_pull_profiles | jq -e '[.[] | select(.profile_index == 2)] | length == 0' >/dev/null
echo "OK  mobile profile delete"
