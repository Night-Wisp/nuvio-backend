// Resolves display metadata (name + poster) for a batch of content ids, so a
// dashboard showing watch progress / watched history (which only stores
// content_id/content_type — see sync_pull_watch_progress) can render
// something more useful than a bare id.
//
// Doing this server-side avoids one browser CORS request per Stremio addon
// per item, and lets us cache results across users instead of every client
// re-resolving the same imdb id.
//
// Contract:
//   POST /functions/v1/resolve-metadata
//   Headers:
//     Authorization: Bearer <user's Supabase JWT>
//     Content-Type: application/json
//   Body:
//     {
//       items: [{ id: string, type: string }, ...],
//       profile_id?: number   // 1-6, defaults to 1
//     }
//   Response:
//     { items: [{ id, type, name: string | null, poster: string | null }, ...] }
//   Unresolved items are returned with name/poster set to null (the array
//   always has one entry per unique requested item, in first-seen order),
//   rather than omitted, so the client can zip the response back onto its
//   original list by index or by (id, type).
//
// Resolution order per item, stopping at the first hit:
//   1. The caller's own library_items for the given profile (already has a
//      name/poster from when the item was added).
//   2. metadata_cache (a shared, non-user-scoped cache this function
//      populates as it resolves items elsewhere).
//   3. The profile's enabled addons that advertise a "meta" resource for
//      the item's type/id, tried in the profile's addon sort order.
//   4. Cinemeta (https://v3-cinemeta.strem.io), as a fallback for
//      movie/series ids that have no better source.
//
// Everything after step 1 is best-effort and bounded (see the *_CAP
// constants below) so one request can't hang the function or hammer a slow
// addon — items that don't resolve within those bounds just come back null.

import "jsr:@supabase/functions-js@2.108.2/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.108.2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const MAX_ITEMS = 200; // hard cap on unique items handled per request
const MAX_ADDONS = 20; // hard cap on addons fetched per profile
const FETCH_TIMEOUT_MS = 3000;
const CONCURRENCY = 10;
const ADDON_LOOKUP_ITEM_CAP = 40; // items eligible for the (slower) addon phase
const ADDONS_PER_ITEM_CAP = 6; // addons tried per item within that phase
const CINEMETA_ITEM_CAP = 80;
const CACHE_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30 days
const CINEMETA_BASE = "https://v3-cinemeta.strem.io";

type RequestItem = { id: string; type: string };
type ResultEntry = { id: string; type: string; name: string | null; poster: string | null };
type ManifestResource = string | { name: string; types?: string[]; idPrefixes?: string[] };
type Manifest = { types?: string[]; resources?: ManifestResource[] };
type ResolvedAddon = { base: string; manifest: Manifest; label: string };
type CacheRow = { id: string; type: string; name: string; poster: string | null; source: string };

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    return json({ error: "server_misconfigured" }, 500);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return json({ error: "missing_authorization_header" }, 401);
  }

  let body: { items?: unknown; profile_id?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400);
  }

  const profileId = normalizeProfileId(body.profile_id);
  if (profileId === null) {
    return json({ error: "invalid_profile_id" }, 400);
  }

  const uniqueItems = normalizeItems(body.items);
  if (uniqueItems.length === 0) {
    return json({ items: [] });
  }

  // User-scoped client: verifies the JWT and lets RLS restrict library_items
  // / addons reads to rows this caller actually owns.
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData.user) {
    return json({ error: "invalid_or_expired_session" }, 401);
  }

  // Service-role client: metadata_cache has no anon/authenticated grants
  // since it isn't user-scoped data.
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const resolved = new Map<string, ResultEntry>();
  const toCache: CacheRow[] = [];

  // 1. Library items already carry a name/poster.
  try {
    const { data, error } = await userClient
      .from("library_items")
      .select("content_id,content_type,name,poster")
      .eq("profile_id", profileId)
      .in(
        "content_id",
        uniqueItems.map((it) => it.id)
      );
    if (!error && data) {
      for (const row of data) {
        const key = keyOf({ id: row.content_id, type: row.content_type });
        if (!resolved.has(key) && row.name) {
          resolved.set(key, { id: row.content_id, type: row.content_type, name: row.name, poster: row.poster ?? null });
        }
      }
    }
  } catch {
    // best-effort; fall through to the remaining sources
  }

  // 2. Shared cache from previous resolutions.
  const afterLibrary = uniqueItems.filter((it) => !resolved.has(keyOf(it)));
  if (afterLibrary.length > 0) {
    try {
      const cutoff = new Date(Date.now() - CACHE_TTL_MS).toISOString();
      const { data, error } = await admin
        .from("metadata_cache")
        .select("content_id,content_type,name,poster,updated_at")
        .in(
          "content_id",
          afterLibrary.map((it) => it.id)
        )
        .gte("updated_at", cutoff);
      if (!error && data) {
        for (const row of data) {
          const key = keyOf({ id: row.content_id, type: row.content_type });
          if (!resolved.has(key) && row.name) {
            resolved.set(key, { id: row.content_id, type: row.content_type, name: row.name, poster: row.poster ?? null });
          }
        }
      }
    } catch {
      // best-effort
    }
  }

  // 3. The profile's enabled addons, tried in priority order.
  const afterCache = uniqueItems.filter((it) => !resolved.has(keyOf(it)));
  if (afterCache.length > 0) {
    try {
      const { data: addonRows, error } = await userClient
        .from("addons")
        .select("url,name,sort_order")
        .eq("profile_id", profileId)
        .eq("enabled", true)
        .order("sort_order", { ascending: true })
        .limit(MAX_ADDONS);

      if (!error && addonRows && addonRows.length > 0) {
        const manifests = await mapWithConcurrency(addonRows, CONCURRENCY, async (addon) => {
          try {
            const manifest = await fetchJson<Manifest>(manifestUrl(addon.url), FETCH_TIMEOUT_MS);
            if (!manifest) return null;
            return { base: addonBaseUrl(addon.url), manifest, label: addon.name ?? addon.url } as ResolvedAddon;
          } catch {
            return null;
          }
        });
        const resolvedAddons = manifests.filter((a): a is ResolvedAddon => a !== null);

        if (resolvedAddons.length > 0) {
          const addonPhaseItems = afterCache.slice(0, ADDON_LOOKUP_ITEM_CAP);
          const tasks: { item: RequestItem; addon: ResolvedAddon }[] = [];
          for (const item of addonPhaseItems) {
            const candidates = resolvedAddons
              .filter((a) => supportsMeta(a.manifest, item.type, item.id))
              .slice(0, ADDONS_PER_ITEM_CAP);
            for (const addon of candidates) tasks.push({ item, addon });
          }

          const taskResults = await mapWithConcurrency(tasks, CONCURRENCY, async (task) => {
            try {
              const url = `${task.addon.base}/meta/${encodeURIComponent(task.item.type)}/${encodeURIComponent(task.item.id)}.json`;
              const payload = await fetchJson<{ meta?: Record<string, unknown> }>(url, FETCH_TIMEOUT_MS);
              const meta = (payload?.meta ?? payload) as Record<string, unknown> | undefined;
              const name = typeof meta?.name === "string" ? meta.name : null;
              if (!name) return null;
              const poster = typeof meta?.poster === "string" ? meta.poster : null;
              return { key: keyOf(task.item), entry: { id: task.item.id, type: task.item.type, name, poster }, source: task.addon.label };
            } catch {
              return null;
            }
          });

          // Iterate in task order (item, then addon priority) so the
          // highest-priority addon that resolved an item wins even though
          // the fetches themselves ran concurrently.
          for (const result of taskResults) {
            if (!result) continue;
            if (!resolved.has(result.key)) {
              resolved.set(result.key, result.entry);
              toCache.push({ ...result.entry, source: result.source });
            }
          }
        }
      }
    } catch {
      // best-effort
    }
  }

  // 4. Cinemeta as a last resort for movie/series ids.
  const afterAddons = uniqueItems.filter(
    (it) => !resolved.has(keyOf(it)) && (it.type === "movie" || it.type === "series")
  );
  if (afterAddons.length > 0) {
    const cinemetaItems = afterAddons.slice(0, CINEMETA_ITEM_CAP);
    const cinemetaResults = await mapWithConcurrency(cinemetaItems, CONCURRENCY, async (item) => {
      try {
        const url = `${CINEMETA_BASE}/meta/${encodeURIComponent(item.type)}/${encodeURIComponent(item.id)}.json`;
        const payload = await fetchJson<{ meta?: Record<string, unknown> }>(url, FETCH_TIMEOUT_MS);
        const meta = (payload?.meta ?? payload) as Record<string, unknown> | undefined;
        const name = typeof meta?.name === "string" ? meta.name : null;
        if (!name) return null;
        const poster = typeof meta?.poster === "string" ? meta.poster : null;
        return { key: keyOf(item), entry: { id: item.id, type: item.type, name, poster } };
      } catch {
        return null;
      }
    });
    for (const result of cinemetaResults) {
      if (!result) continue;
      if (!resolved.has(result.key)) {
        resolved.set(result.key, result.entry);
        toCache.push({ ...result.entry, source: "cinemeta" });
      }
    }
  }

  if (toCache.length > 0) {
    try {
      const rows = toCache.map((c) => ({
        content_id: c.id,
        content_type: c.type,
        name: c.name,
        poster: c.poster,
        source: c.source,
        updated_at: new Date().toISOString(),
      }));
      await admin.from("metadata_cache").upsert(rows, { onConflict: "content_id,content_type" });
    } catch {
      // caching is an optimization, not a requirement for a correct response
    }
  }

  const items: ResultEntry[] = uniqueItems.map((it) => resolved.get(keyOf(it)) ?? { id: it.id, type: it.type, name: null, poster: null });
  return json({ items });
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function keyOf(item: { id: string; type: string }): string {
  return `${item.type}::${item.id}`;
}

function normalizeProfileId(raw: unknown): number | null {
  if (raw === undefined || raw === null) return 1;
  if (typeof raw !== "number" || !Number.isInteger(raw)) return null;
  if (raw < 1 || raw > 6) return null;
  return raw;
}

function normalizeItems(raw: unknown): RequestItem[] {
  if (!Array.isArray(raw)) return [];
  const seen = new Set<string>();
  const out: RequestItem[] = [];
  for (const entry of raw) {
    if (!entry || typeof entry !== "object") continue;
    const id = (entry as Record<string, unknown>).id;
    const type = (entry as Record<string, unknown>).type;
    if (typeof id !== "string" || id.length === 0) continue;
    if (typeof type !== "string" || type.length === 0) continue;
    const key = `${type}::${id}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({ id, type });
    if (out.length >= MAX_ITEMS) break;
  }
  return out;
}

function manifestUrl(url: string): string {
  const trimmed = url.trim().replace(/\/+$/, "");
  return trimmed.endsWith("/manifest.json") ? trimmed : `${trimmed}/manifest.json`;
}

function addonBaseUrl(url: string): string {
  return url.trim().replace(/\/manifest\.json\/?$/, "").replace(/\/+$/, "");
}

function supportsMeta(manifest: Manifest, type: string, id: string): boolean {
  if (!Array.isArray(manifest.resources)) return false;
  for (const resource of manifest.resources) {
    const name = typeof resource === "string" ? resource : resource.name;
    if (name !== "meta") continue;
    const types = typeof resource === "string" ? manifest.types : resource.types ?? manifest.types;
    if (Array.isArray(types) && types.length > 0 && !types.includes(type)) continue;
    const idPrefixes = typeof resource === "object" ? resource.idPrefixes : undefined;
    if (Array.isArray(idPrefixes) && idPrefixes.length > 0 && !idPrefixes.some((prefix) => id.startsWith(prefix))) continue;
    return true;
  }
  return false;
}

async function fetchJson<T>(url: string, timeoutMs: number): Promise<T | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, { signal: controller.signal, headers: { Accept: "application/json" } });
    if (!res.ok) return null;
    return (await res.json()) as T;
  } finally {
    clearTimeout(timer);
  }
}

async function mapWithConcurrency<T, R>(items: T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  async function worker() {
    while (true) {
      const i = next++;
      if (i >= items.length) return;
      results[i] = await fn(items[i]);
    }
  }
  const workerCount = Math.max(1, Math.min(limit, items.length));
  await Promise.all(Array.from({ length: workerCount }, () => worker()));
  return results;
}
