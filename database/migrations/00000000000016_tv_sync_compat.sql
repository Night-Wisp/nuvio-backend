BEGIN;

-- Nuvio TV sync compatibility fixes found by comparing the TV client's sync
-- protocol with this backend:
--   1. Delta event ids for one account are assigned in commit order.
--   2. Deleting a profile (or restoring a backup) keeps the delete events other
--      devices need to learn about the deletions.
--   3. sync_copy_profile_setup, used when a TV creates a profile from another.
--   4. Addon and plugin pushes tolerate repeated URLs, and the plugin push
--      records its origin client id like every other push.

-------------------------------------------------------------------------------
-- 1. Delta event ordering.
--
-- Event ids come from a sequence and are assigned when a row is inserted, but
-- become visible only at commit. If a transaction holding a higher id commits
-- before one holding a lower id, a device that pulls in between advances its
-- cursor past the lower id and never receives that event. Serialise event
-- inserts per account: take a transaction-scoped advisory lock, then draw the
-- id from the sequence, so ids for one account are visible in id order. The
-- lock is held until the writing transaction ends. Ids drawn by the column
-- default are discarded, which leaves harmless gaps.
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assign_sync_event_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $function$
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('nuvio.sync_events:' || NEW.user_id::text, 0)
    );
    NEW.event_id := nextval(TG_ARGV[0]::regclass);
    RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.assign_sync_event_id() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS assign_sync_event_id ON public.watch_progress_events;
CREATE TRIGGER assign_sync_event_id
BEFORE INSERT ON public.watch_progress_events
FOR EACH ROW
EXECUTE FUNCTION public.assign_sync_event_id('public.watch_progress_events_event_id_seq');

DROP TRIGGER IF EXISTS assign_sync_event_id ON public.watched_item_events;
CREATE TRIGGER assign_sync_event_id
BEFORE INSERT ON public.watched_item_events
FOR EACH ROW
EXECUTE FUNCTION public.assign_sync_event_id('public.watched_item_events_event_id_seq');

DROP TRIGGER IF EXISTS assign_sync_event_id ON public.library_item_events;
CREATE TRIGGER assign_sync_event_id
BEFORE INSERT ON public.library_item_events
FOR EACH ROW
EXECUTE FUNCTION public.assign_sync_event_id('public.library_item_events_event_id_seq');

-------------------------------------------------------------------------------
-- 2. Keep delete events when a profile is deleted.
--
-- The delete triggers on watch_progress and library_items emit a tombstone for
-- every removed row, and the previous version of this helper then deleted all
-- of the profile's event rows, tombstones included. watched_items has no delete
-- trigger, so its rows were removed without any event at all. A device holding
-- a cursor never learned that the profile's watch progress, watched items and
-- library entries were removed. The helper now keeps the event tables and
-- writes the missing watched-item tombstones itself. Account deletion still
-- removes the events through the auth.users cascade, and tombstones are skipped
-- while that cascade is running because the user row is already gone. This also
-- covers account restore, which deletes profiles after writing its own
-- tombstones and clearing watched_items.
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_profile_scoped_data(
    p_user_id uuid,
    p_profile_id integer
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $function$
begin
    if p_user_id is null or p_profile_id is null then
        return;
    end if;

    delete from public.addons
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.plugins
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.collections
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.home_catalog_settings
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.media_servers
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.profile_settings_blobs
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.profile_tracker_settings
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.provider_credentials
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.user_tracker_tokens
    where user_id = p_user_id and profile_id = p_profile_id;

    -- Triggers emit the delete events for watch progress and library items.
    -- Those events are kept on purpose.
    delete from public.watch_progress
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.library_items
    where user_id = p_user_id and profile_id = p_profile_id;

    -- Skipped during an account-deletion cascade, when the user row is gone and
    -- the events would violate their foreign key.
    if exists (select 1 from auth.users where id = p_user_id) then
        insert into public.watched_item_events (
            user_id,
            profile_id,
            operation,
            content_id,
            content_type,
            title,
            season,
            episode,
            watched_at
        )
        select
            w.user_id,
            w.profile_id,
            'delete',
            w.content_id,
            w.content_type,
            coalesce(w.title, ''),
            w.season,
            w.episode,
            coalesce(w.watched_at, 0)
        from public.watched_items w
        where w.user_id = p_user_id
          and w.profile_id = p_profile_id;
    end if;

    delete from public.watched_items
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.sync_push_audit_logs
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.user_activity_events
    where user_id = p_user_id and profile_id = p_profile_id;
end;
$function$;

-------------------------------------------------------------------------------
-- 3. sync_copy_profile_setup.
--
-- Called by the TV when a new profile is created from an existing one. Copies
-- the per-platform settings blobs and, optionally, the provider credentials
-- from the source profile to the target profile. Both profiles must already
-- exist for the sync owner. The result carries the statuses the TV validates:
-- tv_status is copied|unchanged and provider_credentials_status is
-- copied|copied_partial|kept_existing|unchanged|source_missing. The mobile and
-- desktop statuses are extra fields that the TV ignores.
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_copy_profile_setup(
    p_source_profile_id integer,
    p_target_profile_id integer,
    p_copy_tv boolean DEFAULT true,
    p_copy_mobile boolean DEFAULT false,
    p_copy_desktop boolean DEFAULT false,
    p_copy_provider_credentials boolean DEFAULT false,
    p_replace_provider_credentials boolean DEFAULT false,
    p_origin_client_id text DEFAULT NULL
)
RETURNS TABLE (
    source_profile_id integer,
    target_profile_id integer,
    tv_status text,
    mobile_status text,
    desktop_status text,
    provider_credentials_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $function$
declare
    v_user_id uuid := public.get_sync_owner();
    v_platform text;
    v_requested boolean;
    v_status text;
    v_source_json jsonb;
    v_target_json jsonb;
    v_copied integer;
    v_kept integer;
begin
    if p_source_profile_id is null or p_source_profile_id < 1 or p_source_profile_id > 6
       or p_target_profile_id is null or p_target_profile_id < 1 or p_target_profile_id > 6 then
        raise exception 'Invalid profile id'
            using errcode = '22023';
    end if;

    if p_source_profile_id = p_target_profile_id then
        raise exception 'Source and target profiles must differ'
            using errcode = '22023';
    end if;

    if (select count(*)
        from public.profiles p
        where p.user_id = v_user_id
          and p.profile_index in (p_source_profile_id, p_target_profile_id)) <> 2 then
        raise exception 'Profile not found'
            using errcode = '22023';
    end if;

    perform public.sync_set_origin_client_id(p_origin_client_id);

    source_profile_id := p_source_profile_id;
    target_profile_id := p_target_profile_id;
    tv_status := 'unchanged';
    mobile_status := 'unchanged';
    desktop_status := 'unchanged';
    provider_credentials_status := 'unchanged';

    foreach v_platform in array array['tv', 'mobile', 'desktop']
    loop
        v_requested := case v_platform
            when 'tv' then coalesce(p_copy_tv, false)
            when 'mobile' then coalesce(p_copy_mobile, false)
            else coalesce(p_copy_desktop, false)
        end;
        v_status := 'unchanged';

        if v_requested then
            select b.settings_json
            into v_source_json
            from public.profile_settings_blobs b
            where b.user_id = v_user_id
              and b.profile_id = p_source_profile_id
              and b.platform = v_platform;

            if found then
                select b.settings_json
                into v_target_json
                from public.profile_settings_blobs b
                where b.user_id = v_user_id
                  and b.profile_id = p_target_profile_id
                  and b.platform = v_platform
                for update;

                if not found or v_target_json is distinct from v_source_json then
                    insert into public.profile_settings_blobs (user_id, profile_id, platform, settings_json)
                    values (v_user_id, p_target_profile_id, v_platform, v_source_json)
                    on conflict (user_id, profile_id, platform)
                    do update set
                        settings_json = excluded.settings_json,
                        updated_at = now();
                    v_status := 'copied';
                end if;
            end if;
        end if;

        if v_platform = 'tv' then
            tv_status := v_status;
        elsif v_platform = 'mobile' then
            mobile_status := v_status;
        else
            desktop_status := v_status;
        end if;
    end loop;

    if coalesce(p_copy_provider_credentials, false) then
        if not exists (
            select 1
            from public.provider_credentials c
            where c.user_id = v_user_id
              and c.profile_id = p_source_profile_id
        ) then
            provider_credentials_status := 'source_missing';
        else
            select
                count(*) filter (
                    where t.provider is null
                       or (coalesce(p_replace_provider_credentials, false)
                           and t.credential_json is distinct from s.credential_json)
                ),
                count(*) filter (
                    where t.provider is not null
                      and not coalesce(p_replace_provider_credentials, false)
                      and t.credential_json is distinct from s.credential_json
                )
            into v_copied, v_kept
            from public.provider_credentials s
            left join public.provider_credentials t
                on t.user_id = s.user_id
               and t.profile_id = p_target_profile_id
               and t.provider = s.provider
            where s.user_id = v_user_id
              and s.profile_id = p_source_profile_id;

            insert into public.provider_credentials (user_id, profile_id, provider, credential_json, updated_at)
            select s.user_id, p_target_profile_id, s.provider, s.credential_json, now()
            from public.provider_credentials s
            where s.user_id = v_user_id
              and s.profile_id = p_source_profile_id
            on conflict (user_id, profile_id, provider)
            do update set
                credential_json = excluded.credential_json,
                updated_at = now()
            where coalesce(p_replace_provider_credentials, false)
              and public.provider_credentials.credential_json is distinct from excluded.credential_json;

            provider_credentials_status := case
                when v_copied > 0 and v_kept > 0 then 'copied_partial'
                when v_copied > 0 then 'copied'
                when v_kept > 0 then 'kept_existing'
                else 'unchanged'
            end;
        end if;
    end if;

    return next;
end;
$function$;

REVOKE ALL ON FUNCTION public.sync_copy_profile_setup(integer, integer, boolean, boolean, boolean, boolean, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sync_copy_profile_setup(integer, integer, boolean, boolean, boolean, boolean, boolean, text) TO authenticated, service_role;

-------------------------------------------------------------------------------
-- 4. Addon and plugin pushes.
--
-- A payload that repeats a URL made the single INSERT ... ON CONFLICT fail
-- with "cannot affect row a second time", rejecting the whole push. Keep the
-- last occurrence of each URL, in payload order, before calling the push.
-- The plugin push also set a differently named origin setting that nothing
-- reads; it now uses sync_set_origin_client_id like every other push.
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_dedupe_url_entries(p_entries jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog
AS $function$
    select case
        when p_entries is null or jsonb_typeof(p_entries) <> 'array' then p_entries
        else coalesce(
            (
                select jsonb_agg(s.entry order by s.ord)
                from (
                    select
                        t.entry,
                        t.ord,
                        coalesce(jsonb_typeof(t.entry -> 'url') = 'string', false) as has_url,
                        row_number() over (
                            partition by case
                                when jsonb_typeof(t.entry -> 'url') = 'string' then t.entry ->> 'url'
                            end
                            order by t.ord desc
                        ) as occurrence
                    from jsonb_array_elements(p_entries) with ordinality as t(entry, ord)
                ) s
                where not s.has_url or s.occurrence = 1
            ),
            '[]'::jsonb
        )
    end;
$function$;

REVOKE ALL ON FUNCTION public.sync_dedupe_url_entries(jsonb) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.sync_push_addons(
    p_addons jsonb,
    p_profile_id integer,
    p_origin_client_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $function$
begin
    perform public.sync_set_origin_client_id(p_origin_client_id);
    perform public.sync_push_addons(public.sync_dedupe_url_entries(p_addons), p_profile_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.sync_push_plugins(
    p_plugins jsonb,
    p_profile_id integer,
    p_origin_client_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $function$
begin
    perform public.sync_set_origin_client_id(p_origin_client_id);
    perform public.sync_push_plugins(public.sync_dedupe_url_entries(p_plugins), p_profile_id);
end;
$function$;

-------------------------------------------------------------------------------
-- Pin the search path of the grouped watch-history function.
--
-- Migrations 11 and 13 created it with search_path = public, unlike every other
-- SECURITY DEFINER function here, which tests/assert-schema.sh requires to use
-- the hardened path. The body schema-qualifies every relation and function.
-------------------------------------------------------------------------------
ALTER FUNCTION public.sync_pull_watched_items_grouped(integer, integer, integer)
    SET search_path = pg_catalog, public, auth, extensions, pg_temp;

NOTIFY pgrst, 'reload schema';

INSERT INTO nuvio_migrations.schema_migrations (version)
VALUES ('00000000000016')
ON CONFLICT (version) DO NOTHING;

COMMIT;
