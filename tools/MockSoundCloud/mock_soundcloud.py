#!/usr/bin/env python3
"""A mock `api-v2.soundcloud.com` that serves the owner's own local music.

Why this exists
---------------
`DemoSeed` (in `SoundingTV.swiftpm/Sources/Design/DesignSystem.swift`) points
every demo track at `https://example.com/stream/<id>`, which resolves to
nothing. That is fine for screenshots, but it means `MixEngine` can never arm
a deck: `SourceImporter.materialise` downloads the remote URL before it can
decode anything, and there is nothing to download. The entire DJ path — decode,
resample, two-deck scheduling, crossfade — has therefore only ever run inert.

This serves real audio, in SoundCloud's *shape*, from files the owner already
has, so that path runs for real:

    GET /catalog                -> [Track, ...]                (api-v2 `/tracks?ids=` shape)
    GET /tracks/<id>            -> Track
    GET /tracks?ids=1,2         -> [Track, ...]
    GET /stream/<id>            -> {"url": "<audio url>"}      (the JSON second hop)
    GET /audio/<id>             -> the audio bytes, with Range support
    GET /waveform/<id>.json     -> {"width":…, "height":…, "samples":[…]}
    GET /artwork/<id>.jpg       -> cover art
    GET /me                     -> User
    GET /health                 -> {"ok": true, "tracks": n}

`~/Music` is treated as strictly read-only: files are opened `rb` and nothing
else. Every derived artefact (waveform JSON, extracted cover art) is written to
a separate cache directory, never next to the source.

Range requests are the non-negotiable part. `AVPlayer` seeks by issuing
`Range: bytes=…` and expects `206 Partial Content` with a correct
`Content-Range`; without that, seeking is broken and time-to-first-audio is
awful because AVFoundation falls back to pulling the whole file. `HEAD` is
answered too, because AVFoundation probes with it before ranging.

Usage
-----
    python3 tools/MockSoundCloud/mock_soundcloud.py            # 127.0.0.1:8787
    python3 tools/MockSoundCloud/mock_soundcloud.py --port 9000
    python3 tools/MockSoundCloud/mock_soundcloud.py --snippet-demo

Then launch the tvOS app with:

    SIMCTL_CHILD_SOUNDING_TV_DEMO=1 \
    SIMCTL_CHILD_SOUNDING_TV_STREAM_HOST=http://127.0.0.1:8787 \
    xcrun simctl launch --console <device> red.forbes.sounding

The server prints that line on startup with the port it actually bound.

Requires `ffmpeg`/`ffprobe` on PATH (Homebrew) for duration probing, waveform
generation and cover-art extraction. Nothing else — stdlib only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import threading
import urllib.parse
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

# The date format `SoundCloudAPI`'s decoder is configured with. A track whose
# `created_at` does not parse fails `Track.init(from:)` outright — `createdAt`
# is a non-optional `decode`, not `decodeIfPresent`.
DATE_FORMAT = "%Y-%m-%dT%H:%M:%SZ"

# SoundCloud's own waveform documents are 1800 buckets tall 140. Matching the
# real shape means `Waveform.resampled(to:)` and the rank-mapping in
# `WaveformService` are exercised on the same magnitudes they see in
# production, rather than on a conveniently small array.
WAVEFORM_WIDTH = 1800
WAVEFORM_HEIGHT = 140

# Peak detection rate for the waveform. The document is a *visual* envelope, so
# full 44.1 kHz buys nothing a human can see; 11025 Hz keeps transients while
# making a six-minute track decode in well under a second.
WAVEFORM_RATE = 11025

CONTENT_TYPES = {
    ".mp3": "audio/mpeg",
    ".m4a": "audio/mp4",
    ".mp4": "audio/mp4",
    ".aac": "audio/aac",
    ".aif": "audio/aiff",
    ".aiff": "audio/aiff",
    ".wav": "audio/wav",
    ".flac": "audio/flac",
    ".ogg": "audio/ogg",
    ".opus": "audio/opus",
}

# What `Transcoding.codec` will classify each container as. Kept explicit
# rather than derived from the MIME type so the mapping is auditable: the app
# ranks `lossless > aac > mp3 > opus`, and getting this wrong would silently
# change which transcoding wins.
PRESETS = {
    ".mp3": ("mp3_1_0", "audio/mpeg"),
    ".m4a": ("aac_256k", "audio/mp4; codecs=\"mp4a.40.2\""),
    ".mp4": ("aac_256k", "audio/mp4; codecs=\"mp4a.40.2\""),
    ".aac": ("aac_256k", "audio/mp4; codecs=\"mp4a.40.2\""),
    ".aif": ("flac_0_0", "audio/x-aiff"),
    ".aiff": ("flac_0_0", "audio/x-aiff"),
    ".wav": ("flac_0_0", "audio/wav"),
    ".flac": ("flac_0_0", "audio/flac"),
}


# --------------------------------------------------------------------------
# ffmpeg helpers
# --------------------------------------------------------------------------

def _require(tool: str) -> str:
    path = shutil.which(tool)
    if not path:
        sys.exit(
            f"error: `{tool}` not found on PATH. Install with `brew install ffmpeg`."
        )
    return path


def probe(path: Path) -> dict:
    """Duration / channels / sample rate / embedded tags, via ffprobe."""
    out = subprocess.run(
        [
            _require("ffprobe"), "-v", "error",
            "-print_format", "json",
            "-show_format", "-show_streams",
            str(path),
        ],
        capture_output=True, text=True, check=True,
    ).stdout
    return json.loads(out)


def audio_duration(meta: dict) -> float:
    for stream in meta.get("streams", []):
        if stream.get("codec_type") == "audio" and stream.get("duration"):
            return float(stream["duration"])
    return float(meta.get("format", {}).get("duration", 0.0))


def has_cover_art(meta: dict) -> bool:
    for stream in meta.get("streams", []):
        if stream.get("codec_type") == "video":
            return True
    return False


def tag(meta: dict, *names: str) -> str | None:
    """First non-empty value among `names`, searching format then stream tags."""
    pools = [meta.get("format", {}).get("tags", {})]
    pools += [s.get("tags", {}) for s in meta.get("streams", [])]
    for pool in pools:
        lowered = {k.lower(): v for k, v in (pool or {}).items()}
        for name in names:
            value = lowered.get(name.lower())
            if value and str(value).strip():
                return str(value).strip()
    return None


# --------------------------------------------------------------------------
# Derived artefacts (cached; never written next to the source)
# --------------------------------------------------------------------------

def build_waveform(path: Path, cache_dir: Path) -> list[int]:
    """Real peak envelope, computed from the real audio.

    This is the whole point of serving real music: `WaveformService` renders
    whatever this returns, so a rendered waveform in the app is evidence about
    the *audio*, not about a generator. Peaks (not RMS) because SoundCloud's
    own documents are peak envelopes, and because peak is what makes a
    breakdown legible as a dip.
    """
    key = hashlib.sha256(
        f"{path}|{path.stat().st_size}|{path.stat().st_mtime_ns}|{WAVEFORM_WIDTH}".encode()
    ).hexdigest()[:24]
    cached = cache_dir / f"waveform-{key}.json"
    if cached.exists():
        return json.loads(cached.read_text())["samples"]

    raw = subprocess.run(
        [
            _require("ffmpeg"), "-v", "error",
            "-i", str(path),
            "-ac", "1", "-ar", str(WAVEFORM_RATE),
            "-f", "s16le", "-",
        ],
        capture_output=True, check=True,
    ).stdout

    import array
    pcm = array.array("h")
    pcm.frombytes(raw[: len(raw) - (len(raw) % 2)])
    if sys.byteorder != "little":
        pcm.byteswap()

    n = len(pcm)
    if n == 0:
        samples = [0] * WAVEFORM_WIDTH
    else:
        samples = []
        for i in range(WAVEFORM_WIDTH):
            start = i * n // WAVEFORM_WIDTH
            end = max(start + 1, (i + 1) * n // WAVEFORM_WIDTH)
            peak = 0
            for j in range(start, end):
                v = pcm[j]
                v = -v if v < 0 else v
                if v > peak:
                    peak = v
            samples.append(min(WAVEFORM_HEIGHT, round(peak / 32768 * WAVEFORM_HEIGHT)))

    cached.write_text(json.dumps(
        {"width": WAVEFORM_WIDTH, "height": WAVEFORM_HEIGHT, "samples": samples}
    ))
    return samples


def build_artwork(path: Path, cache_dir: Path, meta: dict, track_id: int) -> Path:
    """Embedded cover art if the file has one, otherwise a deterministic tile.

    The fallback is generated with ffmpeg's `color` source rather than a
    drawing library so the tool stays stdlib-only. Its hue is derived from the
    track id, so each track is visually distinct and the same track is the
    same colour on every run.
    """
    out = cache_dir / f"artwork-{track_id}.jpg"
    if out.exists():
        return out

    if has_cover_art(meta):
        result = subprocess.run(
            [_require("ffmpeg"), "-v", "error", "-y", "-i", str(path),
             "-an", "-vframes", "1", str(out)],
            capture_output=True,
        )
        if result.returncode == 0 and out.exists() and out.stat().st_size > 0:
            return out

    hue = (track_id * 47) % 360
    subprocess.run(
        [_require("ffmpeg"), "-v", "error", "-y",
         "-f", "lavfi",
         "-i", f"color=c=0x{_hsv_hex(hue)}:s=500x500",
         "-frames:v", "1", str(out)],
        capture_output=True, check=True,
    )
    return out


def _hsv_hex(hue: int) -> str:
    """Saturated, dark-ish RGB hex for a hue in 0..359 (no colorsys import fuss)."""
    import colorsys
    r, g, b = colorsys.hsv_to_rgb(hue / 360.0, 0.55, 0.55)
    return f"{int(r * 255):02x}{int(g * 255):02x}{int(b * 255):02x}"


# --------------------------------------------------------------------------
# Catalogue
# --------------------------------------------------------------------------

def build_trim(path: Path, cache_dir: Path, start: float, seconds: float) -> Path:
    """A shortened copy of a real track, written to the cache dir.

    `~/Music` is never touched: `-i <source>` reads, the output goes to our
    own scratch directory. Re-encoded rather than stream-copied so the result
    starts on a clean frame boundary — a stream copy of an mp3 leaves a
    partial first frame, which AVFoundation reports as a slightly different
    duration than ffprobe does, and the DJ engine's mix-point maths is
    computed off the declared duration.

    Why this exists: the auto-mix fires at `duration - mixSeconds`, so
    demonstrating a real transition on a six-minute track means waiting five
    and a half minutes per attempt. Trimming to ~75 s makes the same code path
    observable in about forty seconds, with real music through it.
    """
    key = hashlib.sha256(
        f"{path}|{path.stat().st_size}|{start}|{seconds}".encode()
    ).hexdigest()[:24]
    out = cache_dir / f"trim-{key}{path.suffix.lower()}"
    if out.exists() and out.stat().st_size > 0:
        return out
    subprocess.run(
        [_require("ffmpeg"), "-v", "error", "-y",
         "-ss", f"{start}", "-t", f"{seconds}", "-i", str(path),
         "-map", "0:a:0", "-ac", "2", str(out)],
        capture_output=True, check=True,
    )
    return out


class MockTrack:
    def __init__(self, entry: dict, index: int, cache_dir: Path, base_url: str,
                 snippet: bool = False, trim: float | None = None):
        self.source_path = Path(os.path.expanduser(entry["path"]))
        self.path = self.source_path
        trim_seconds = entry.get("trim", trim)
        trim_start = float(entry.get("trim_start", 0))
        if trim_seconds:
            self.path = build_trim(self.source_path, cache_dir,
                                   trim_start, float(trim_seconds))
        self.id = int(entry.get("id") or (7001 + index))
        self.meta = probe(self.path)
        self.duration = audio_duration(self.meta)
        self.bpm = entry.get("bpm")
        self.key = entry.get("key")
        self.note = entry.get("note", "")
        self.snippet = snippet

        self.title = (
            entry.get("title")
            or tag(self.meta, "title")
            or self.path.stem
        )
        self.artist = (
            entry.get("artist")
            or tag(self.meta, "artist", "album_artist")
            or "Local Library"
        )
        self.genre = entry.get("genre") or tag(self.meta, "genre") or "Electronic"
        self.cache_dir = cache_dir
        self.base_url = base_url
        self.size = self.path.stat().st_size
        self.ext = self.path.suffix.lower()

        self._waveform: list[int] | None = None
        self._artwork: Path | None = None

    # -- derived, lazily and cached --------------------------------------

    def waveform(self) -> list[int]:
        if self._waveform is None:
            self._waveform = build_waveform(self.path, self.cache_dir)
        return self._waveform

    def artwork(self) -> Path:
        if self._artwork is None:
            self._artwork = build_artwork(self.path, self.cache_dir, self.meta, self.id)
        return self._artwork

    # -- api-v2 shapes ----------------------------------------------------

    def user_json(self) -> dict:
        # A stable synthetic id per artist name, so two tracks by the same
        # artist really do come back as the same user object.
        uid = 9_000_000 + int(hashlib.sha256(self.artist.encode()).hexdigest()[:6], 16) % 900_000
        handle = re.sub(r"[^a-z0-9]+", "-", self.artist.lower()).strip("-") or "artist"
        return {
            "id": uid,
            "username": handle,
            "permalink": handle,
            "permalink_url": f"https://soundcloud.com/{handle}",
            "avatar_url": f"{self.base_url}/artwork/{self.id}.jpg",
            "city": None,
            "country": None,
            "full_name": self.artist,
            "description": None,
            "track_count": 1,
            "playlist_count": 0,
            "followers_count": 1234,
            "followings_count": 56,
        }

    def transcodings(self) -> list[dict]:
        preset, mime = PRESETS.get(self.ext, ("mp3_1_0", "audio/mpeg"))
        base = {
            "url": f"{self.base_url}/stream/{self.id}",
            "preset": preset,
            "duration": int(self.duration * 1000),
            "quality": "hq",
            # `false`, and honestly so: this is the complete file, not a
            # 30-second preview. `Track.init(from:)` filters `snipped == true`
            # out — that filter is the app's entitlement enforcement point and
            # nothing here weakens it. `--snippet-demo` flips this to `true`
            # for one track precisely so the enforcement can be *observed*
            # working, not bypassed.
            "snipped": self.snippet,
            "format": {"protocol": "progressive", "mime_type": mime},
        }
        return [base]

    def track_json(self) -> dict:
        return {
            "id": self.id,
            "title": self.title,
            "description": self.note or None,
            "artwork_url": f"{self.base_url}/artwork/{self.id}.jpg",
            "waveform_url": f"{self.base_url}/waveform/{self.id}.json",
            "permalink_url": f"https://soundcloud.com/mock/{self.id}",
            "playback_count": 100_000 + self.id * 37,
            "likes_count": 1_000 + self.id * 7,
            "reposts_count": 42,
            "created_at": datetime(2024, 9, 1, 12, 0, 0, tzinfo=timezone.utc).strftime(DATE_FORMAT),
            "genre": self.genre,
            "tag_list": self.genre,
            "bpm": self.bpm,
            "key_signature": self.key,
            "duration": int(self.duration * 1000),
            "full_duration": int(self.duration * 1000),
            "streamable": True,
            "user": self.user_json(),
            "media": {"transcodings": self.transcodings()},
        }


class Catalog:
    def __init__(self, entries: list[dict], cache_dir: Path, base_url: str,
                 snippet_demo: bool, trim: float | None = None):
        self.tracks: list[MockTrack] = []
        skipped: list[str] = []
        for index, entry in enumerate(entries):
            path = Path(os.path.expanduser(entry["path"]))
            if not path.exists():
                skipped.append(str(path))
                continue
            snippet = bool(snippet_demo and entry.get("snippet_demo"))
            self.tracks.append(MockTrack(entry, index, cache_dir, base_url,
                                         snippet, trim))
        self.skipped = skipped
        self.by_id = {t.id: t for t in self.tracks}

    def me_json(self) -> dict:
        return {
            "id": 9990001,
            "username": "afr",
            "permalink": "afr",
            "permalink_url": "https://soundcloud.com/afr",
            "avatar_url": "https://i1.sndcdn.com/avatars-000387272834-fkfd2d-large.jpg",
            "city": "London",
            "country": "United Kingdom",
            "full_name": "Alex Forbes-Reed",
            "description": None,
            "track_count": len(self.tracks),
            "playlist_count": 1,
            "followers_count": 4823,
            "followings_count": 612,
        }

    def stream_json(self, limit: int) -> dict:
        """`GET /stream` — the Stream/feed, in the shape `FeedActivity`
        (SoundingTV.swiftpm/Sources/Models/FeedActivity.swift) decodes:
        `type` discriminator (`track`/`track-repost`), `created_at`, a
        top-level `user` (the actor — the track's own owner for a plain
        post, a *different* artist for a repost, so the reposted-by
        attribution the real screen exists for has something real to
        render), and the track itself.

        Every other track alternates into a repost, attributed to the next
        artist in the catalogue (wrapping around) — deliberately not the
        same artist as the track, which is the one case the app has to get
        right (see that model's own doc comment on `isRepost`). One page,
        `next_href: None`: this mock has no real pagination story and the
        client already tolerates that (`PageCursor.canLoadMore` reads
        `next_href` and simply stops).
        """
        entries = []
        now = datetime.now(timezone.utc)
        tracks = self.tracks[:limit] if limit > 0 else self.tracks
        for index, track in enumerate(tracks):
            is_repost = index % 2 == 1 and len(tracks) > 1
            # Prefer a reposter whose synthetic artist id actually differs
            # from the track's own owner — several manifest tracks can share
            # one artist tag (e.g. a sample pack's whole demo set), and
            # picking `tracks[index + 1]` blindly can land on that same
            # artist, making the "Reposted by" attribution invisible even
            # though the JSON shape is correct. Falls back to the plain
            # neighbour when every track really does share one artist.
            actor = track.user_json()
            if is_repost:
                candidate = next(
                    (t for t in tracks if t.user_json()["id"] != track.user_json()["id"]),
                    tracks[(index + 1) % len(tracks)],
                )
                actor = candidate.user_json()
            created_at = now.replace(microsecond=0) - timedelta(minutes=index * 7)
            entries.append({
                "type": "track-repost" if is_repost else "track",
                "created_at": created_at.strftime(DATE_FORMAT),
                "uuid": f"mock-stream-{track.id}-{'repost' if is_repost else 'post'}",
                "user": actor,
                "track": track.track_json(),
            })
        return {"collection": entries, "next_href": None}


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

RANGE_RE = re.compile(r"^bytes=(\d*)-(\d*)$")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    catalog: Catalog = None  # type: ignore[assignment]
    verbose = False

    # -- plumbing ---------------------------------------------------------

    def log_message(self, fmt, *args):  # noqa: A003 - BaseHTTPRequestHandler API
        if Handler.verbose:
            sys.stderr.write("  %s %s\n" % (self.address_string(), fmt % args))

    def _send_json(self, payload, status=200, head_only=False):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def _send_error_json(self, status, message, head_only=False):
        self._send_json({"error": message}, status=status, head_only=head_only)

    # -- file serving with Range ------------------------------------------

    def _send_file(self, path: Path, content_type: str, head_only: bool):
        """`206 Partial Content` when asked, `200` otherwise.

        AVFoundation's asset loader probes with `HEAD` (or a tiny opening
        range), reads `Accept-Ranges`/`Content-Length`, and then seeks by
        issuing further ranges. Answering `200` with the whole body to a
        ranged request makes seeking silently wrong and is the single most
        common way a hand-rolled media server fails.
        """
        try:
            size = path.stat().st_size
        except OSError:
            self._send_error_json(404, "not found", head_only)
            return

        rng = self.headers.get("Range")
        start, end = 0, size - 1
        partial = False

        if rng:
            match = RANGE_RE.match(rng.strip())
            if not match:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            lo, hi = match.group(1), match.group(2)
            if lo == "":
                # `bytes=-500` — the trailing N bytes.
                suffix = int(hi or 0)
                if suffix <= 0:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                start = max(0, size - suffix)
                end = size - 1
            else:
                start = int(lo)
                end = int(hi) if hi else size - 1
            if start >= size or start > end:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            end = min(end, size - 1)
            partial = True

        length = end - start + 1
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", content_type)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

        if head_only:
            return

        remaining = length
        # `~/Music` is read-only here and everywhere else in this tool: `rb`,
        # never `r+b`/`wb`, and no rename/utime/xattr calls anywhere.
        with open(path, "rb") as handle:
            handle.seek(start)
            while remaining > 0:
                chunk = handle.read(min(262_144, remaining))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    # AVFoundation abandons ranges routinely — it opens a
                    # speculative read, gets what it needs, and drops the
                    # socket. That is normal, not an error.
                    return
                remaining -= len(chunk)

    # -- routes -----------------------------------------------------------

    def do_HEAD(self):  # noqa: N802 - BaseHTTPRequestHandler API
        self._route(head_only=True)

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        self._route(head_only=False)

    def _route(self, head_only: bool):
        parsed = urllib.parse.urlparse(self.path)
        parts = [p for p in parsed.path.split("/") if p]
        query = urllib.parse.parse_qs(parsed.query)
        cat = Handler.catalog

        try:
            if parts == ["health"]:
                self._send_json({"ok": True, "tracks": len(cat.tracks)}, head_only=head_only)
                return

            if parts == ["catalog"]:
                self._send_json([t.track_json() for t in cat.tracks], head_only=head_only)
                return

            if parts == ["me"]:
                self._send_json(cat.me_json(), head_only=head_only)
                return

            if parts == ["stream"]:
                limit = int(query.get("limit", ["20"])[0]) if query.get("limit", ["20"])[0].isdigit() else 20
                self._send_json(cat.stream_json(limit), head_only=head_only)
                return

            if parts == ["tracks"] and "ids" in query:
                wanted = [int(x) for x in query["ids"][0].split(",") if x.strip().isdigit()]
                found = [cat.by_id[i].track_json() for i in wanted if i in cat.by_id]
                self._send_json(found, head_only=head_only)
                return

            if len(parts) == 2 and parts[0] == "tracks" and parts[1].isdigit():
                track = cat.by_id.get(int(parts[1]))
                if not track:
                    self._send_error_json(404, "no such track", head_only)
                    return
                self._send_json(track.track_json(), head_only=head_only)
                return

            # The JSON second hop. SoundCloud's `transcodings[].url` is not the
            # audio — it is an endpoint that returns the (signed, short-lived)
            # audio URL. `SoundCloudAPI.getStreamURL(for:)` makes this call for
            # every track that plays, so the mock has to answer it in the same
            # shape or that whole function goes untested.
            if len(parts) == 2 and parts[0] == "stream" and parts[1].isdigit():
                track = cat.by_id.get(int(parts[1]))
                if not track:
                    self._send_error_json(404, "no such track", head_only)
                    return
                self._send_json({"url": f"{track.base_url}/audio/{track.id}{track.ext}"},
                                head_only=head_only)
                return

            if len(parts) == 2 and parts[0] == "audio":
                stem = parts[1].split(".")[0]
                track = cat.by_id.get(int(stem)) if stem.isdigit() else None
                if not track:
                    self._send_error_json(404, "no such track", head_only)
                    return
                ctype = CONTENT_TYPES.get(track.ext) or mimetypes.guess_type(track.path.name)[0] \
                    or "application/octet-stream"
                self._send_file(track.path, ctype, head_only)
                return

            if len(parts) == 2 and parts[0] == "waveform":
                stem = parts[1].split(".")[0]
                track = cat.by_id.get(int(stem)) if stem.isdigit() else None
                if not track:
                    self._send_error_json(404, "no such track", head_only)
                    return
                self._send_json(
                    {"width": WAVEFORM_WIDTH, "height": WAVEFORM_HEIGHT,
                     "samples": track.waveform()},
                    head_only=head_only,
                )
                return

            # `DemoSeed.fixture(for:)`'s pre-mock answer for the second hop.
            # Nothing should reach this — `isMockHostURL` lets the real
            # `/stream/{id}` endpoint answer instead — so hitting it means
            # that guard is gone and *every* track is about to be analysed as
            # whichever one this serves. Say so loudly rather than quietly
            # playing the wrong song.
            if parts == ["demo-stream-unresolved.mp3"]:
                sys.stderr.write(
                    "  ! /demo-stream-unresolved.mp3 was requested — the app is NOT "
                    "resolving per-track stream URLs. Check DemoSeed.isMockHostURL.\n"
                )
                track = cat.tracks[0]
                self._send_file(track.path, CONTENT_TYPES.get(track.ext, "audio/mpeg"), head_only)
                return

            if len(parts) == 2 and parts[0] == "artwork":
                stem = parts[1].split(".")[0]
                track = cat.by_id.get(int(stem)) if stem.isdigit() else None
                if not track:
                    self._send_error_json(404, "no such track", head_only)
                    return
                self._send_file(track.artwork(), "image/jpeg", head_only)
                return

            # Anything unrecognised answers like an empty api-v2 list rather
            # than erroring: the app treats a 404 as a real failure, and a
            # mock that 404s on a route nobody thought of turns into a
            # debugging red herring.
            self._send_json({"collection": [], "next_href": None}, head_only=head_only)
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as exc:  # pragma: no cover - defensive
            sys.stderr.write(f"  ! {self.path}: {exc!r}\n")
            try:
                self._send_error_json(500, str(exc), head_only)
            except Exception:
                pass


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def main() -> int:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1",
                        help="bind address (default 127.0.0.1; use 0.0.0.0 for a real Apple TV)")
    parser.add_argument("--port", type=int, default=8787, help="port (default 8787; 0 picks a free one)")
    parser.add_argument("--tracks", type=Path, default=here / "tracks.json",
                        help="track manifest (default tools/MockSoundCloud/tracks.json)")
    parser.add_argument("--cache-dir", type=Path,
                        default=Path(os.environ.get("TMPDIR", "/tmp")) / "mock-soundcloud",
                        help="where derived waveform/artwork artefacts are cached")
    parser.add_argument("--advertise", default=None,
                        help="base URL to embed in responses (default http://<host>:<port>)")
    parser.add_argument("--trim", type=float, default=None, metavar="SECONDS",
                        help="serve shortened copies (written to --cache-dir, never to ~/Music) "
                             "so the auto-mix window arrives in seconds instead of minutes")
    parser.add_argument("--snippet-demo", action="store_true",
                        help="mark the manifest's `snippet_demo` track as snipped, to observe "
                             "the app's entitlement filter refusing to play it")
    parser.add_argument("--verbose", action="store_true", help="log every request")
    args = parser.parse_args()

    _require("ffmpeg")
    _require("ffprobe")

    args.cache_dir.mkdir(parents=True, exist_ok=True)

    manifest = json.loads(args.tracks.read_text())
    entries = manifest["tracks"] if isinstance(manifest, dict) else manifest

    # Bind first so `--port 0` can be advertised with the port it actually got.
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    bound_port = server.server_address[1]
    advertise = args.advertise or f"http://{args.host}:{bound_port}"

    print(f"Mock SoundCloud — indexing {len(entries)} track(s)…", flush=True)
    catalog = Catalog(entries, args.cache_dir, advertise, args.snippet_demo, args.trim)
    Handler.catalog = catalog
    Handler.verbose = args.verbose

    if catalog.skipped:
        print("  ! missing on disk, skipped:")
        for path in catalog.skipped:
            print(f"      {path}")
    if not catalog.tracks:
        sys.exit("error: no playable tracks in the manifest")

    # Precompute up front, on a worker, so the first play doesn't stall behind
    # an ffmpeg decode. Failures here are non-fatal — the route recomputes.
    def warm():
        for track in catalog.tracks:
            try:
                track.waveform()
                track.artwork()
            except Exception as exc:
                sys.stderr.write(f"  ! warm {track.title}: {exc!r}\n")
        print("  waveforms + artwork ready", flush=True)

    threading.Thread(target=warm, daemon=True).start()

    print()
    for track in catalog.tracks:
        bpm = f"{track.bpm:g} BPM" if track.bpm else "— BPM"
        key = track.key or "—"
        mins = int(track.duration // 60)
        secs = int(track.duration % 60)
        flag = "  [SNIPPET]" if track.snippet else ""
        print(f"  {track.id}  {track.title[:44]:<44} {bpm:>9}  {key:<4} "
              f"{mins}:{secs:02d}  {track.size / 1_048_576:5.1f} MB  {track.ext}{flag}")
    print()
    print(f"  listening on {advertise}")
    print(f"  cache        {args.cache_dir}")
    print()
    print("  launch the tvOS app with:")
    print(f"    SIMCTL_CHILD_SOUNDING_TV_DEMO=1 \\")
    print(f"    SIMCTL_CHILD_SOUNDING_TV_STREAM_HOST={advertise} \\")
    print(f"    xcrun simctl launch --console <device> red.forbes.sounding")
    print(flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
