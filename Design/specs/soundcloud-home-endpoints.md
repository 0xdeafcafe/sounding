# api-v2 discovery endpoints — what Home can actually be built from

Written for task #126 ("home/stream ugly *and pointless*"), after the owner
corrected the premise: **the Stream is not Home.** Home is a discovery
surface; the Stream is a chronological activity feed of people you follow.
Building Home out of the Stream is why it reads as pointless.

One doc for all three platforms (tvOS, iOS, macOS) so nobody re-derives this.

## How this was obtained — and how to redo it

Not from docs (there are none for api-v2). From **SoundCloud's own web
client**, which is the authoritative list of what the API can do:

```bash
curl -sSL -A "<a desktop Safari UA>" https://soundcloud.com/discover -o home.html
grep -oE 'https://[a-z0-9\-]+\.sndcdn\.com/[^"]*\.js' home.html   # 8 entry chunks
# the entry chunk carries a webpack chunk map {id:"<hash>",…}; expand it to
# https://a-v2.sndcdn.com/assets/<id>-<hash>.js and fetch all 58 chunks
```

Inside `55-*.js` there is a **single literal route table** — 187 routes,
123 of them GET — of the form

```js
{activities:{method:i,service:l,path:"activities"}, …,
 mixedSelections:{method:i,service:l,path:"mixed-selections"}, …}
```

(`i/o/a/s` = GET/POST/PUT/DELETE; `l` = `"api-v2"`.) That table *is* the API
surface. The web client's own `client_id` is in the same bundles
(`client_id:"…"`), which is what made the unauthenticated probing below
possible without a user token.

Everything marked **verified** below was probed live against
`https://api-v2.soundcloud.com` on 2026-08-04 with that `client_id` and no
OAuth token. Known already, not re-derived: base host, `Authorization: OAuth
<token>` **header** (the `?oauth_token=` query param is ignored by api-v2).

### One correction to a "known fact"

`CLAUDE.md`/prior task briefs state **"there is no recently-played endpoint;
`/me/play-history` does not exist."** That is **wrong**. The route table
contains:

| Route | Method | Probe |
|---|---|---|
| `me/play-history/tracks` | GET | **401** with client_id only — exists, needs auth |
| `me/play-history/contexts` | GET | **401** — exists, needs auth |
| `me/play-history` | POST | (add) |
| `me/play-history` | DELETE | (clear) |

A 401 (not a 404) is the proof: the route resolves, it just refuses an
anonymous caller. **Its response shape has NOT been verified** — that needs a
real signed-in token, which this pass did not have. Verify before building
on it. The on-device `TopShelfStore` recents shelf remains a working
substitute in the meantime, and has something the endpoint probably does not:
a resume `progress` per entry.

---

## 1. Verified, unauthenticated (client_id only) — these can fill Home today

### 1.1 `GET /mixed-selections` — **the single most valuable endpoint here**

This is literally SoundCloud's own web home. Optional params seen in the web
client: `datetime`, `country`, `curation-staging`; `limit` works.

- Response: `{ collection: [Selection], next_href, query_urn }`
- `Selection`: `{ urn, query_urn, title, description, tracking_feature_name,
  last_updated, style, social_proof, social_proof_users, items: { collection:
  [...] }, kind: "selection", id }`
- `id` values seen anonymously: `soundcloud:selections:trending-by-genre-playlists`
  ("Trending by genre", 15 playlists), `…:buzzing` ("Artists to watch out
  for", 8), `…:personalised-curated-global` ("Curated by SoundCloud", 10),
  plus a rotating `…:promo-campaign-*` (8, **mixed** `playlist` + `user`).
- Item objects are ordinary api-v2 playlists: `id` (Int), `title`,
  `permalink_url`, `created_at`, `artwork_url`, `track_count`, `user`,
  `is_album`, `likes_count`, `duration` — **no `tracks` key**, so our
  `Playlist` model decodes them with `tracks == nil`, `trackIDs == nil`.
  `getPlaylist(id:)` hydrates on open exactly as it already does elsewhere.

**The server supplies the shelf titles and descriptions.** That is the whole
"editorial voice" Apple's Home has and ours does not — we do not have to
invent one. The web client caches this per user (`hashFn` keys on `me.id`),
and one anonymous selection is already named "personalised-…", so it is very
likely **more personal when called with a token** — unverified, worth
checking the moment a token is available.

Caveat to design around: item kinds are **heterogeneous** (`playlist` *and*
`user`). A shelf renderer must skip kinds it can't present, and a selection
that empties out after filtering must be dropped, not rendered empty.

### 1.2 `GET /charts?kind=<trending|top>&genre=<genre-urn>` — verified

- ⚠️ **CORRECTED 2026-08-04, re-probed.** This previously said `kind=top` 404s
  for `all-music` but "works for other genres". Measured: **`kind=top` 404s for
  every genre tried**, and **`kind=trending` 404s for every genre EXCEPT
  `all-music`** (tried `alltrap`, `house`, `hiphoprap`, `electronic`). So
  `charts` is effectively **`all-music`-only anonymously**. Per-genre charts
  come from **`charts/selections`** instead — server-titled, which is better
  anyway: no genre table to hard-code and go stale.
  The original wording is the exact shape to avoid — it generalised "works for
  other genres" from a single failing probe rather than testing one.
- `genre` is a URN: `soundcloud:genres:all-music`, `…:hiphoprap`, etc.
- Response: `{ genre, kind, last_updated, collection: [{ score, track }],
  query_urn, next_href }` — note the **`{score, track}` wrapper**; this is
  not a `Page<Track>`.
- `track` is a full track object **with `media.transcodings` (8 present)**,
  `policy`, `monetization_model` — so `Track.init`'s entitlement filtering
  applies unchanged and `streamURL` resolves normally.

### 1.3 `GET /charts/selections` — verified

`{ collection: [Selection] }` in the same shape as `mixed-selections`, but the
items are chart playlists: "Music Charts US" / "Music Charts UK", each 10
playlists ("All music genres", "New & Hot", "Hip Hop", …). A ready-made
"Charts" shelf with no genre list to hard-code.

### 1.4 `GET /tracks/:id/related` — verified

`{ collection: [Track], next_href, query_urn, variant: "sim_sounds_v3" }`.
Full tracks with transcodings. **This is the honest "More Like This" shelf**
and it needs no new personal data at all — seed it from the last played
track (`TopShelfStore` recents) or a recent like.

### 1.5 `GET /system-playlists/:urn` — verified, and this is how Stations work

Every track object carries `station_urn` /`station_permalink`. Fetching
`system-playlists/soundcloud%3Asystem-playlists%3Atrack-stations%3A<trackId>`
returns **200** with a 50-track station. `artist-stations:<userId>` works the
same way (verified against Flume, `playlist_type: "ARTIST_STATION"`,
`short_title: "Flume"`, `calculated_artwork_url` present).

Two things to know before building on it:
- The `tracks` array is **stubs** (4 keys each, no title/media) — hydrate via
  the existing `getTracks(ids:)` / `PlaylistTrackCursor` machinery.
- A system-playlist is **not** shape-compatible with our `Playlist` model:
  `id` is a string URN, and there is no `created_at` and no `user`, both of
  which `Playlist.init` decodes as required. It needs its own model.

`personalized-tracks::<id>` returned **500** — not a valid urn form; do not
guess urn shapes, read them off `station_urn`.

### 1.6 `GET /featured_tracks/:kind/:genre` — ⚠️ DO NOT USE

**CORRECTED 2026-08-04.** This section previously read "verified — 200, 12
tracks with transcodings", and the doc proposed
`getFeaturedTracks(...) -> Page<Track>`. **That method would have thrown on
every call.** The 200 carries 12 **partial** track objects: no `user`, no
`created_at`. `Page<Track>` fails on all 12, and `Page` then correctly refuses
the false-empty page.

**No method was added.** `charts` answers the same question in one round trip
with server framing. A self-test pins the partial shape so a change is noticed.

The lesson: a **200 is not a verified endpoint**. This was marked "verified"
because it returned tracks-shaped JSON — the decode was never attempted. Prove
an endpoint by compiling the real model against the real captured body, which
is how the `Playlist` vs `system-playlist` mismatch was also caught.

`featured_tracks/:pageName` (the one-segment form) returned **400**.

### 1.7 Artist-relative, verified (empty for curator accounts, populated for real artists — probed against Flume, id 2976616)

| Route | Result |
|---|---|
| `users/:id/relatedartists` | 10 `user`s |
| `users/:id/toptracks` | 27 `track`s |
| `users/:id/spotlight` | 2 `playlist`s |
| `users/:id/featured-profiles` | 0 (exists, often empty) |
| `recent-tracks/:tag` | 4 `track`s (tag is a plain word, e.g. `electronic`) |

### 1.8 Verified-but-useless anonymously

`playlists/discovery` → 200 with an **empty** collection every time tried
(with and without `tag`). Probably needs auth and/or params the web client
supplies elsewhere. Do not build a shelf on it until it returns something.

---

## 2. Verified to EXIST, needs a token (401 with client_id only)

Shapes unverified — **verify each before building on it.**

| Route | Likely use |
|---|---|
| `me/play-history/tracks` | **Recently Played** (see the correction above) |
| `me/play-history/contexts` | what you were playing *from* |
| `me/artist-shortcuts` (+ `me/artist-shortcuts/stories/:artist_urn`) | the web's artist "stories" rail |
| `me/library/stations` | **Stations you've saved** — Apple's "Stations for You" analogue |
| `me/suggested/users/who_to_follow` | Who to follow |
| `me/shortcuts/followings`, `me/shortcuts/track-likes`, `me/shortcuts/own-tracks` | fast id lists |
| `me/system_playlist_likes/urns` | which system playlists/stations are liked |

## 3. Endpoints that do NOT exist

Anything not in the 187-route table. Specifically asked about and **absent**:
`/recommendations`, `/suggestions` (only `search/suggest/tags` and
`me/suggested/users/who_to_follow` exist), `/explore`. `/charts` exists but
**not** as a bare call — it 400s without `kind` + `genre`.

---

## 4. What Home should be, given the above

Ranked by "answers a distinct question" — the test the owner's "pointless"
complaint is really about. Every one of these is fillable; anything not
listed here is not.

| Shelf | Question it answers | Source | Module |
|---|---|---|---|
| SoundCloud's own selections (server-titled, N shelves) | "what's worth hearing right now" | `mixed-selections` | editorial 410×550 |
| Continue Listening | "what was I in the middle of" | `TopShelfStore` recents (has resume progress), later `me/play-history/tracks` | 260 tile + progress |
| More Like *<last played>* | "more of what I just enjoyed" | `tracks/:id/related` seeded from recents | 260 tile |
| Trending / Charts | "what's moving" | `charts?kind=trending&genre=…`, `charts/selections` | 260 tile / editorial |
| Stations | "put something on and leave it" | `system-playlists/…track-stations:<id>` seeded from a like/recent; `me/library/stations` once authed | editorial |
| Your Mixes & Playlists | "collections I already keep" | `getLikedPlaylists` + `getUserPlaylists` (**exist today**) | editorial 410×550 |
| New From Artists You Follow | "what my follows posted" | `getStream` (**exists today**) | 260 tile |
| Your Likes | "what I already said I love" | `getLikedTracks` (**exists today**) | 260 tile |

The last three are what Home can render **today**; the first five all need
new `SoundCloudAPI` methods.

## 5. `SoundCloudAPI` additions needed (Services/ — not editable in task #126)

```swift
// api-v2 responses that are NOT Page<Track>:
struct Selection: Decodable { let id, title: String; let description: String?
                              let items: Page<SelectionItem> }        // §1.1
enum SelectionItem { case playlist(Playlist), user(User) }            // kind discriminator
struct ChartEntry: Decodable { let score: Double; let track: Track }   // §1.2

func getMixedSelections(country: String? = nil) async throws -> Page<Selection>
func getChartSelections() async throws -> Page<Selection>
func getCharts(kind: String, genreURN: String, limit: Int) async throws -> ChartsPage
func getRelatedTracks(trackId: String, limit: Int) async throws -> Page<Track>
func getFeaturedTracks(kind: String, genre: String, limit: Int) async throws -> Page<Track>
func getSystemPlaylist(urn: String) async throws -> SystemPlaylist   // NOT Playlist, see §1.5
func getPlayHistory(limit: Int) async throws -> Page<PlayHistoryItem> // shape UNVERIFIED
```

`buildURL` and `request` are `private`, so none of this can be added from a
view file — these have to land in `Services/SoundCloudAPI.swift`.

Two rules that carry over unchanged: `isTokenValid` must keep failing open,
and **entitlement filtering in `Track.init` must not be bypassed** — every
discovery payload above carries real `media.transcodings`, so the existing
enforcement point works on all of them with no special-casing.

---

## THE APP SENDS NEITHER CREDENTIAL'S FALLBACK — measured 2026-08-04

Read this before quoting any "works anonymously" line above. Every anonymous
result in this document was probed **with the web client's `client_id`**.
api-v2 accepts *either* a `client_id` *or* an `Authorization: OAuth` header,
and answers a request carrying **neither** with a 401. Measured across `/me`,
`/stream`, `/me/library/all` and `/mixed-selections` — all 401 bare.

`buildURL` (`SoundCloudAPI.swift:118`) **never sends a `client_id`.** Its only
appended query item is `oauth_token`, which api-v2 ignores outright (the old v1
convention; that it is ignored is why the header was centralised).

So **the app has no anonymous mode at all** — no degraded content, no generic
editorial fallback, no partial Home. The `Authorization` header is a single
point of failure for the entire app's networking: if it is absent for any
reason, every request in every tab 401s at once. That presents as "can't load
on every tab", a Library that renders *empty* rather than errored, and a
Profile that spins forever — which is exactly the shape of the 2026-08-04
user report.

Whether to send a `client_id` so a signed-out phone can show the four generic
selections is a **product decision for the owner**, not a bug fix, and doing it
casually would mask auth failures rather than fix them.

---

## AUTHENTICATED PROBE — 2026-08-04, real Go+ account (`consumer-high-tier`)

Everything below was previously listed as "exists (401) but shape unverified".
Probed with a real token; **no token value appears anywhere in this document.**

### `GET /mixed-selections` authenticated — this IS Home, and it personalises

Anonymous: 4 generic editorial selections, ~50KB.
**Authenticated: 12 selections, 122 items, ~346KB.** Several URNs are keyed to
the user id, so the "likely personalised with a token" hypothesis is
**confirmed, not assumed**:

| Title (server-supplied — render verbatim) | URN | items |
|---|---|---|
| More of what you like | `selections:personalized-tracks:<uid>` | 20 |
| **Recently Played** | `selections:recently-played:<uid>` | 20 |
| Mixed for <display name> | `selections:your-moods` | 10 |
| Made for you | `selections:made-for-you` | 2 |
| Liked By | `selections:liked-by-<uid>` | 8 |
| New crew, suggested for you | `selections:friends-of-friends` | 10 |
| Discover with Stations | `selections:artist-stations` | 5 |
| Albums for you | `selections:personalized-albums` | 5 |
| (promo campaign, time-limited) | `selections:promo-campaign-…` | 9 |
| Trending by genre | `selections:trending-by-genre-playlists` | 15 |
| Artists to watch out for | `selections:buzzing` | 8 |
| Curated by SoundCloud | `selections:personalised-curated-global` | 10 |

**One authenticated call composes the whole Home screen**, server-titled and
server-ordered. That is the direct answer to "feed is not home": Stream is
chronological posts from people you follow; this is the editorial and
personalised surface, and we were rendering the former in the latter's place.

Note the promo-campaign entry is time-limited and its title is a full sentence.
**Do not hard-code titles or assume a fixed selection set** — render what the
server sends, skip what you can't decode, and never present an empty selection.

### `me/play-history/tracks` — **200**, works

`{ collection: [{ played_at, track_id, track }], next_href, query_urn }`, where
`track` is a full `Track`. So a real Recently Played exists at track
granularity, *and* as a ready-made shelf inside `mixed-selections` above.

⚠️ This directly refutes the long-standing claim in `BACKLOG.md` and
`sync-coverage.md` that no recently-played source existed. Both are corrected.

### `me/play-history/contexts` — **200**

`{ played_at, kind, context_urn, user, station, playlist, system_playlist }` —
what you were playing *from*. `kind` discriminates; the matching object is
populated and the others are null.

### `me/artist-shortcuts` — **200**, ~28KB

`{ collection: [{ user_urn, unread_update_at, has_read, user }] }` — the
"artists with something new" row Apple Music runs along the top of Listen Now.
`has_read`/`unread_update_at` give an unread state we could honour.

### `me/library/stations` — **200**, empty collection

Exists and is reachable; this account simply has no stations. Do not conclude
it is unimplemented — an empty collection is a valid answer, and a shelf built
on it must contribute nothing rather than render empty.
