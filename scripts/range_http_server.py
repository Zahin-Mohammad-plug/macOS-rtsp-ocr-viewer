#!/usr/bin/env python3
"""Static file server with HTTP Range support (python's http.server lacks it,
and players need ranges to read MP4 files that keep their index at the end).
Usage: range_http_server.py <directory> <port>   (binds 127.0.0.1)"""
import http.server, os, re, sys

class RangeHandler(http.server.SimpleHTTPRequestHandler):
    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path) or not os.path.exists(path):
            return super().send_head()
        size = os.path.getsize(path)
        match = re.match(r"bytes=(\d*)-(\d*)$", self.headers.get("Range", ""))
        if not match:
            self.range = None
            return super().send_head()
        start = int(match.group(1)) if match.group(1) else max(0, size - int(match.group(2)))
        end = int(match.group(2)) if match.group(1) and match.group(2) else size - 1
        end = min(end, size - 1)
        if start > end:
            self.send_error(416)
            return None
        handle = open(path, "rb")
        handle.seek(start)
        self.range = (start, end)
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        return handle

    def copyfile(self, source, outputfile):
        if getattr(self, "range", None) is None:
            return super().copyfile(source, outputfile)
        remaining = self.range[1] - self.range[0] + 1
        while remaining > 0:
            chunk = source.read(min(1 << 16, remaining))
            if not chunk:
                break
            try:
                outputfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError):
                break
            remaining -= len(chunk)

    def end_headers(self):
        if self.command == "GET" and getattr(self, "range", None) is None:
            self.send_header("Accept-Ranges", "bytes")
        super().end_headers()

    def log_message(self, *args):
        pass

if __name__ == "__main__":
    directory, port = sys.argv[1], int(sys.argv[2])
    handler = lambda *a, **k: RangeHandler(*a, directory=directory, **k)
    http.server.ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()
