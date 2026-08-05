import http.server
import socketserver
import sys
import threading
import time

JPEG_PATH = sys.argv[1]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8899
DELAY = float(sys.argv[3]) if len(sys.argv) > 3 else 0.12

with open(JPEG_PATH, "rb") as f:
    JPEG = f.read()

counter_lock = threading.Lock()
count = 0


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        global count
        if self.path == "/count":
            with counter_lock:
                body = str(count).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/reset":
            with counter_lock:
                count = 0
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")
            return
        if self.path.startswith("/art/"):
            with counter_lock:
                count += 1
            time.sleep(DELAY)
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Cache-Control", "public, max-age=604800")
            self.send_header("Content-Length", str(len(JPEG)))
            self.end_headers()
            self.wfile.write(JPEG)
            return
        self.send_response(404)
        self.end_headers()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


print(f"serving on {PORT} delay={DELAY}s jpeg={len(JPEG)}B", flush=True)
Server(("127.0.0.1", PORT), Handler).serve_forever()
