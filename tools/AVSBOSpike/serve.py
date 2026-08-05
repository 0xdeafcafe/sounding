#!/usr/bin/env python3
"""Tiny local HTTP server for the AVPlayerItemSampleBufferOutput spike.

Mimics SoundCloud's second-hop shape just enough for this spike:

    GET /stream/1        -> {"url": "http://127.0.0.1:<port>/hls/stream.m3u8"}
    GET /hls/stream.m3u8  -> the VOD HLS playlist
    GET /hls/seg_XXX.ts   -> the HLS segments

Not a full mock (no Track/catalog shape) -- this spike only needs the JSON
second hop plus real HLS bytes, per CLAUDE.md's stream URL description.
"""
import http.server
import json
import socketserver
import sys
from pathlib import Path

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8799
ROOT = Path(__file__).parent


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def do_GET(self):
        if self.path == "/stream/1":
            body = json.dumps({"url": f"http://127.0.0.1:{PORT}/hls/stream.m3u8"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        return super().do_GET()

    def log_message(self, fmt, *args):
        sys.stderr.write("%s\n" % (fmt % args))


if __name__ == "__main__":
    with socketserver.ThreadingTCPServer(("127.0.0.1", PORT), Handler) as httpd:
        print(f"serving on http://127.0.0.1:{PORT}  (stream hop -> /stream/1)")
        httpd.serve_forever()
