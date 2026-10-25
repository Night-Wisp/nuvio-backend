BEGIN;

-- Full-snapshot pulls are paged with OFFSET. Ordering by the timestamp alone
-- is not deterministic when rows share one (bulk imports, a whole season
-- marked watched, items saved in one batch), so consecutive pages could repeat
-- or skip rows. Add the primary key as a tiebreaker. Signatures, return types
-- and grants are unchanged.
CREATE OR REPLACE FUNCTION public.sync_pull_library(
    p_profile_id integer DEFAULT 1,
    p_limit integer DEFAULT 500,
    p_offset integer DEFAULT 0
)
RETURNS SETOF public.library_items
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $function$
    SELECT * FROM public.library_items
    WHERE user_id = public.get_sync_owner() AND profile_id = p_profile_id
    ORDER BY added_at DESC, id
    LIMIT p_limit
    OFFSET p_offset;
$function$;

CREATE OR REPLACE FUNCTION public.sync_pull_watched_items(
    p_profile_id integer DEFAULT 1,
    p_page integer DEFAULT 1,
    p_page_size integer DEFAULT 100000
)
RETURNS SETOF public.watched_items
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $function$
    SELECT * FROM public.watched_items
    WHERE user_id = public.get_sync_owner() AND profile_id = p_profile_id
    ORDER BY watched_at DESC, id
    LIMIT p_page_size
    OFFSET (p_page - 1) * p_page_size;
$function$;

NOTIFY pgrst, 'reload schema';

INSERT INTO nuvio_migrations.schema_migrations (version)
VALUES ('00000000000015')
ON CONFLICT (version) DO NOTHING;

COMMIT;
