#!/usr/bin/env python3
"""Minimal HTTP server with correct Range/206 support, since Python's stock
http.server ignores Range headers and always returns 200 with the full body
-- which breaks AVFoundation's progressive-download asset loading."""
import http.server
import os
import re
import socketserver
import sys

MIME = {
    ".m4a": "audio/mp4",
    ".mp3": "audio/mpeg",
    ".wav": "audio/wav",
    ".ts": "video/mp2t",
    ".m3u8": "application/vnd.apple.mpegurl",
}


class RangeHandler(http.server.SimpleHTTPRequestHandler):
    def guess_type(self, path):
        ext = os.path.splitext(path)[1]
        if ext in MIME:
            return MIME[ext]
        return super().guess_type(path)

    def do_GET(self):
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            return super().do_GET()

        file_size = os.path.getsize(path)
        range_header = self.headers.get("Range")

        if not range_header:
            self.send_response(200)
            self.send_header("Content-type", self.guess_type(path))
            self.send_header("Content-Length", str(file_size))
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            with open(path, "rb") as f:
                self.wfile.write(f.read())
            return

        m = re.match(r"bytes=(\d*)-(\d*)", range_header)
        if not m:
            self.send_response(416)
            self.end_headers()
            return
        start_s, end_s = m.groups()
        start = int(start_s) if start_s else 0
        end = int(end_s) if end_s else file_size - 1
        end = min(end, file_size - 1)
        length = end - start + 1

        self.send_response(206)
        self.send_header("Content-type", self.guess_type(path))
        self.send_header("Content-Length", str(length))
        self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            remaining = length
            chunk = 64 * 1024
            while remaining > 0:
                data = f.read(min(chunk, remaining))
                if not data:
                    break
                self.wfile.write(data)
                remaining -= len(data)

    def log_message(self, fmt, *args):
        pass  # quiet


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8934
    directory = sys.argv[2] if len(sys.argv) > 2 else "."
    os.chdir(directory)
    server = ThreadingHTTPServer(("127.0.0.1", port), RangeHandler)
    print(f"Serving {directory} on http://127.0.0.1:{port} with Range support")
    server.serve_forever()
