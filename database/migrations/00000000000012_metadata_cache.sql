BEGIN;

-- Backing store for the resolve-metadata edge function. Keyed by
-- (content_id, content_type) since a given piece of content's name/poster
-- is the same regardless of which account looked it up, so this is a
-- shared cache rather than per-user data. Only the edge function (via the
-- service role key) reads or writes it.
CREATE TABLE public.metadata_cache (
    content_id text NOT NULL,
    content_type text NOT NULL,
    name text,
    poster text,
    source text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT metadata_cache_pkey PRIMARY KEY (content_id, content_type)
);

ALTER TABLE public.metadata_cache ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.metadata_cache FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.metadata_cache TO service_role;

COMMENT ON TABLE public.metadata_cache IS
    'Shared name/poster lookup cache populated by the resolve-metadata edge function. Not scoped to a user; service-role access only.';

-- Existing PostgREST containers should pick up the new table immediately
-- after an upgrade, without requiring operators to restart the stack.
NOTIFY pgrst, 'reload schema';

INSERT INTO nuvio_migrations.schema_migrations (version)
VALUES ('00000000000012')
ON CONFLICT (version) DO NOTHING;

COMMIT;
