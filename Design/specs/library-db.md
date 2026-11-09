# Library database

Written 2026-11-09. Owner direction (reverses "LibraryCache is not an offline library"):

> "it does not fetch all soundcloud playlists, liked songs, etc, etc. in one go at the start to back fill the local cache (which is king) and then it should patch changes to that db over time as things change. with that being synced across devices via icloud or local area"

The local library database is the single source of truth for every library screen on every platform. Screens read it and observe it; they never wait on the network. One engine fills it once (backfill), keeps it current (patch), and two transports copy it between the owner's devices (Link over the home network, and iCloud) so a second device doesn't download the library from SoundCloud again.

## 1. Sources

| Source | What it says | How we use it |
|---|---|---|
| [Rate limits](https://developers.soundcloud.com/docs/api/rate-limits) | Per app (`client_id`), a rolling one-minute general budget "on the order of 100 requests per minute". Likes (`GET`/`POST`/`DELETE` on like resources and user like lists): **500 per 24 hours**. Reposts: 500 actions per 24 hours. 429 carries `Retry-After` (seconds) when present, plus `X-Ratelimit-Limit/Remaining/Reset`; the old `errors[].meta.rate_limit.reset_time` body is no longer returned, so don't rely on it. Limits can change; read headers at runtime. | Budgets in §6 sit far inside these. Any 429 stops the engine (§6). The gateway already honours `Retry-After` and the global stop. |
| [Guide: follow and pagination](https://developers.soundcloud.com/docs/api/guide#follow) | Follow is `PUT /me/followings/:user_id`. Collections return 50 by default, **at most 200**; `linked_partitioning=true` gives a `next_href` with an opaque `cursor`; no `next_href` means the end. **No ordering is documented** for followings, likes, playlists or pages. | We follow `next_href` verbatim and never build cursors ourselves. Page size is 200, the documented maximum. Because order isn't documented, the patch never trusts order alone: it stops on a run of known items and is backed by a count check and a weekly full walk (§4). |
| [Guide: authentication](https://developers.soundcloud.com/docs/api/guide#authentication) | `Authorization: OAuth <token>`; access tokens last **about an hour**; **each refresh token is single-use**. | A backfill outlives a token. The engine never refreshes: it goes through `SoundCloudAPI`, whose single refresher (`DeviceSessionRefresher`, §9 of the bible) renews on 401. If a request still ends `unauthorized` or the sign-in is held, the engine parks with its cursor saved and resumes on the next tick. |

The app talks to `api-v2.soundcloud.com` (`users/:id/track_likes`, `users/:id/playlist_likes`, `users/:id/playlists`, `users/:id/followings`, `users/:id/followers`, `users/:id/tracks`, `stream/users/:id/reposts`, `playlists/:id`, `tracks?ids=`). **None of these api-v2 routes are covered by the public docs.** We treat them as if the documented `api.soundcloud.com` limits applied, including the 500-a-day likes limit.

## 2. Collections

A collection is an ordered list of ids owned by the signed-in account.

| Key | Contents | Remote | Newest first? |
|---|---|---|---|
| `likes` | liked tracks, with liked-at time | `users/:me/track_likes` | yes (liked-at) |
| `likedPlaylists` | liked playlists and albums | `users/:me/playlist_likes` | yes |
| `ownPlaylists` | own playlists and albums | `users/:me/playlists` | treated as yes |
| `followings` | users you follow | `users/:me/followings` | yes (observed) |
| `followers` | users following you, first 2,000 | `users/:me/followers` | yes (observed) |
| `reposts` | your reposted tracks and playlists | `stream/users/:me/reposts` | yes |
| `ownTracks` | your uploads | `users/:me/tracks` | yes |
| `playlist.<id>` | the tracks of one liked or own playlist, in order | `playlists/:id` then `tracks?ids=` (50 at a time) | positional |

Sets are generated from `likes` (long liked tracks), so they need nothing extra. Recently Played, Stream, Home and search stay network screens; they aren't the library.

## 3. Tables (in `LibraryCache`'s `library.sqlite3`, WAL)

- `likes_index` (existing): the `likes` collection. `item_id`, `payload` (Track JSON), `liked_at_millis`, folded title and artist, `generation`. Search, Spotlight, Siri entities and Downloads keep reading it.
- `ldb_member(collection, item_key, kind, item_id, sort_key, generation, timestamp_millis)`: every other collection. Ordered by `sort_key DESC`. A backfill appends below the lowest key; a patch puts new items above the highest key.
- `ldb_entity(kind, id, payload, title_fold, artist_fold, change_key)`: one row per track, playlist or user, shared by every collection that holds it. `change_key` for a playlist is `last_modified|track_count`.
- `ldb_cursor(collection, json)`: `LibraryCursor` (phase, `next_href`, generation, fetched, expected total, completed at, patched at, synced change key, last verified).
- `ldb_bucket(collection, bucket, bucket_count, updated_millis, cloud_millis)`: sync bookkeeping (§5).
- `ldb_meta(key, value)`: bound account id, budget counters.

Account scope: the database is bound to one SoundCloud user id. If the signed-in user differs from the bound one, everything is wiped before anything is read, fetched or merged. Sign-out wipes it too. Imports from a peer or iCloud carrying another account id are dropped.

## 4. Engine

`LibrarySyncCore` (pure logic, `LibrarySync.swift`) talks to a `LibraryRemote` and a `LibraryStore` through protocols, and is unit-tested with recorded response shapes. `LibrarySyncEngine` (main actor) adapts it to `SoundCloudAPI`, schedules it and publishes progress.

### Backfill (once, resumable)
Order: likes → own playlists → liked playlists → followings → own tracks → reposts → followers (capped at 2,000) → each playlist's tracks.
- One page per step, persisted before the next request: rows, then `next_href`, so a relaunch resumes at the cursor.
- A walk starts a new generation; at its end, rows of older generations are removed (that's how a full walk detects deletions).
- Playlist tracks: `playlists/:id` gives the ordered id list; ids already in the database (likes, other playlists) aren't fetched; the rest come from `tracks?ids=` 50 at a time. A 404 or 403 playlist is dropped.

### Patch (after the backfill)
- **Newest-first collections** (likes, followings, followers, reposts, own tracks): fetch from the top until a page ends with **20 known items in a row** (or the list ends; at most 10 pages). That window becomes the head: new items go above everything, items already known move to their new place, and any local item ranked above the window's last item that isn't in the window is deleted (an unlike, unfollow or removed repost). With no run of known items after 10 pages the window is still added and a full walk is scheduled.
- **Count check:** after a patch, if the local count differs from SoundCloud's own count on `/me` (`public_favorites_count`, `followings_count`, `followers_count`, `track_count`), a full walk of that collection is scheduled, at most once every 7 days.
- **Weekly verify:** every collection is fully re-walked at most once a week, so deep deletions the head can't see are found.
- **Re-walks keep SoundCloud's order:** a verify or mismatch walk places each item by its position under a fixed base stored in the cursor, so an unchanged list writes identical rows and marks nothing for sync, and a reordered one ends up in SoundCloud's order.
- **Playlists:** both playlist lists are re-walked in full at most once an hour (a few pages); removed playlists are deleted with their track lists. A playlist's tracks are refetched only when its `change_key` (`last_modified|track_count`) differs from the one its track list was fetched at.
- **When:** on foreground, a 60-second tick while in the foreground (heads are due every 15 minutes, playlist lists every hour), and right after the user's own actions. On tvOS the database lives in Caches (Application Support isn't persistent there); the engine starts from `AppRuntime.start`, ahead of Home discovery.
- **User actions are optimistic:** like, unlike, follow, unfollow, like or unlike a playlist, repost or unrepost write the database first, screens update at once, and the request goes out; a failed request reverts the row. A patch of that collection follows 5 s later to reconcile. (There is no add-to-playlist in the app yet; when it lands it uses the same path: write `playlist.<id>`, then patch the playlist.)

## 5. Cross-device sync

Rows travel as **chunks**: a collection is split into buckets by FNV-1a of the id (`bucket = fnv1a(id) % bucketCount`, `bucketCount` a power of two sized so a bucket holds about 100 rows, 1 to 256). A chunk is the full content of one bucket: compact rows (id, sort key, payload, title, artist, change key), JSON then LZFSE, plus the account id, the collection, the bucket, the bucket count, `updatedAtMillis` and the writer. Applying a chunk replaces that bucket's rows, so it's idempotent, and deletions travel with it. A newer `updatedAtMillis` wins per bucket; a local write marks its bucket with the current time. A **manifest** chunk per account carries each collection's cursor (phase, completed at, count).

**A device that adopts a manifest whose collections are complete (completed within 7 days) marks them complete itself and skips its backfill; it only patches.** Its own patch then catches anything newer.

- **Home network (Link):** the iPhone, iPad or Mac pushes chunks to a linked Apple TV over the existing signed `likesSync` Companion message. The body is a `LibraryPeerBody` (`format: "library.1"`, account, LZFSE chunks), opaque to `TokenTransferProtocol.swift`, which stays dependency-free; the TV still accepts the old `LikesPeerBody` from older builds. On connect it sends the manifest and every bucket; afterwards, on each library change, only buckets changed since the connection's high-water mark. Messages are batched to at most 600 KB of chunks (a 1 MB frame after base64); a single chunk over 600 KB is skipped, since a bucket is applied whole. The TV accepts only its own signed-in account.
- **iCloud:** private database, zone `Library`, record type **`LibraryChunk`** (record name `<account>.<collection>.<bucket>`, fields `account` String, `collection` String, `bucket` Int64, `bucketCount` Int64, `payload` Bytes, `updatedAtMillis` Int64, `writerId` String). Dirty buckets are sent on the 30-second sync cadence, at most 40 records (plus the manifest) per run. Records are compact (LZFSE) and under 600 KB. On sign-out the device stops exporting; records of another account are ignored.
- **Schema:** `Design/cloudkit/LibraryChunk.ckdb` is the record type in CloudKit schema language. Development creates it on the first save from a Debug build; to add it ahead of that, export the Development schema with `xcrun cktool export-schema --team-id <team> --container-id iCloud.red.forbes.sounding --environment development --output-file schema.ckdb`, paste the fragment inside `DEFINE SCHEMA`, and `xcrun cktool import-schema … --environment development --file schema.ckdb` (import replaces the whole schema, so always start from an export). Production: deploy from the CloudKit Console (release checklist item 9).

## 6. Budgets

Background only (`SoundCloudRequestEnvironment.autonomous`, metadata lane), so the gateway's ceilings apply on top (12 a minute, 180 an hour, stop at 600 an hour, §9 of the bible).
- About two engine requests in flight, 1.5 to 2.5 s apart (playlist track lists sync two at a time); at most **150 engine requests an hour**, inside the gateway's 180.
- **Up front:** opening Likes, Tracks, Playlists, Albums or Following, and launch for Likes, walks that one list to the end at once on the user lane (`LibrarySyncEngine.prioritise`, `LibrarySyncCore.fill`), 200 a page, publishing each page so the list fills in. The background walker yields to it and resumes from its cursor afterwards.
- Like-list requests (`track_likes`, `playlist_likes`): at most **300 in 24 hours**, leaving 200 of the documented 500 for the user's own likes and screens.
- Followers: at most 10 pages of 200 (2,000 people).
- Foreground only; it pauses when the app leaves the foreground and resumes from the cursor.
- **Any 429**, DataDome challenge, traffic stop or background pause parks the engine until the next tick after the stop ends; it never retries a 429 itself. Other failures retry up to twice with jittered backoff, then the step is skipped until the next tick.
- A 5,400-like library with 60 playlists is roughly 27 + 2 + 3 + 10 + 60 playlists + about 120 `tracks?ids=` batches ≈ 220 requests. Likes come first on the user lane (27 pages, under a minute); the other ≈ 195 take about 20 minutes at 12 a minute, or up to about 1 h 20 min if the 150-an-hour cap is reached. A patch is usually 1 request per collection.
- **iCloud not ready:** if CloudKit refuses `LibraryChunk` (Production schema not deployed), the refused buckets are marked unsent, the lease round is skipped and the device decides alone; iCloud is tried again after 6 hours. No error is shown.

## 7. Status

`LibrarySyncEngine.progress` publishes the phase and per-collection counts. Settings › Library shows one quiet line ("Syncing your library… 3,200 of 5,400 likes", then "Library up to date"), and Likes and Tracks show the same line at the bottom of the list while a backfill runs. No cards.

## 8. Tests

`LibrarySyncCoreTests` (SoundingTVTests) drives the core against a scripted remote built from recorded api-v2 response shapes and a real SQLite store in a temporary directory: backfill and resume, generation pruning, head patch with new, moved and deleted items, the 10-page fallback, the count check, playlist change keys, budgets and 429 parking, optimistic actions and revert, account wipe, chunk encode/apply idempotence, manifest adoption skipping the backfill, and refusing another account's chunks.
