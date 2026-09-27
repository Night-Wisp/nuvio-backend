BEGIN;

-- sync_pull_watched_items_grouped picked season/episode from the row with
-- the max watched_at, i.e. the last-watched episode rather than the
-- furthest-along one. Rewatching an early episode then made that early
-- episode display as the show's progress instead of it. Expose both,
-- distinctly:
--   season / episode / watched_at                        -> the episode
--     tied to the most recent watch activity, which may be an earlier
--     episode if it was rewatched. watched_at is also what
--     pagination/ordering uses for "last activity on this title".
--   furthest_season / furthest_episode / furthest_watched_at -> the
--     furthest-along (highest season, then highest episode) watched
--     entry, for "continue watching" style UI.
DROP FUNCTION IF EXISTS public.sync_pull_watched_items_grouped(integer, integer, integer);

CREATE FUNCTION public.sync_pull_watched_items_grouped(
    p_profile_id integer DEFAULT 1,
    p_page integer DEFAULT 1,
    p_page_size integer DEFAULT 50
)
RETURNS TABLE(
    content_id text,
    content_type text,
    title text,
    season integer,
    episode integer,
    watched_at bigint,
    furthest_season integer,
    furthest_episode integer,
    furthest_watched_at bigint,
    episode_count integer
)
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  WITH grouped AS (
    SELECT
      w.content_id,
      (array_agg(w.content_type ORDER BY w.watched_at DESC))[1] AS content_type,
      (array_agg(w.title ORDER BY w.watched_at DESC))[1] AS title,
      (array_agg(w.season ORDER BY w.watched_at DESC))[1] AS season,
      (array_agg(w.episode ORDER BY w.watched_at DESC))[1] AS episode,
      max(w.watched_at) AS watched_at,
      (array_agg(w.season ORDER BY w.season DESC NULLS LAST, w.episode DESC NULLS LAST))[1] AS furthest_season,
      (array_agg(w.episode ORDER BY w.season DESC NULLS LAST, w.episode DESC NULLS LAST))[1] AS furthest_episode,
      (array_agg(w.watched_at ORDER BY w.season DESC NULLS LAST, w.episode DESC NULLS LAST))[1] AS furthest_watched_at,
      NULLIF(count(*) FILTER (WHERE w.episode IS NOT NULL), 0)::integer AS episode_count
    FROM public.watched_items AS w
    WHERE w.user_id = public.get_sync_owner()
      AND w.profile_id = p_profile_id
    GROUP BY w.content_id
  )
  SELECT content_id, content_type, title, season, episode, watched_at, furthest_season, furthest_episode, furthest_watched_at, episode_count
  FROM grouped
  ORDER BY watched_at DESC, content_id
  LIMIT p_page_size
  OFFSET (p_page - 1) * p_page_size;
$$;

REVOKE ALL ON FUNCTION public.sync_pull_watched_items_grouped(
    integer,
    integer,
    integer
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.sync_pull_watched_items_grouped(
    integer,
    integer,
    integer
) TO authenticated, service_role;

COMMENT ON FUNCTION public.sync_pull_watched_items_grouped(
    integer,
    integer,
    integer
) IS
    'Returns watched history grouped by content_id (one row per series/movie). season/episode/watched_at describe the episode tied to the most recent watch activity, which may be an earlier episode if it was rewatched; watched_at is the max watched_at across the whole group and is what pagination/ordering uses for "last activity on this title". furthest_season/furthest_episode/furthest_watched_at describe the furthest-along (highest season/episode) watched entry, for "continue watching" UI. Does not replace sync_pull_watched_items, which still returns raw per-episode rows for client sync.';

-- Existing PostgREST containers should expose the updated RPC shape
-- immediately after an upgrade, without requiring operators to restart the
-- stack.
NOTIFY pgrst, 'reload schema';

INSERT INTO nuvio_migrations.schema_migrations (version)
VALUES ('00000000000013')
ON CONFLICT (version) DO NOTHING;

COMMIT;
