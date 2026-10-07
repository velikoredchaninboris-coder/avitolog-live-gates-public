import os, sys
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = os.environ.get('CUTOVER_LOCK', '1') != '0'
ROOT = Path(__file__).resolve().parent

if not LOCK:
    backend = ROOT / 'src' / 'backend' / 'runtime'
    if not backend.is_dir():
        raise SystemExit('BACKEND_RUNTIME_MISSING')
    os.chdir(backend)
    os.execvp('uvicorn', ['uvicorn', 'app.main:app', '--host', '0.0.0.0', '--port', os.environ.get('PORT', '10000')])

class Handler(BaseHTTPRequestHandler):
    def _headers(self, status, length=0):
        self.send_response(status)
        self.send_header('Content-Type','application/json')
        self.send_header('Cache-Control','no-store')
        self.send_header('Content-Length',str(length))
        self.end_headers()

    def do_HEAD(self):
        # Render performs HEAD / for liveness. A 200 HEAD exposes no runtime content.
        if self.path in {'/','/healthz','/health'}:
            self._headers(200, 0)
        else:
            self._headers(503, 0)

    def do_GET(self):
        if self.path in {'/healthz','/health'}:
            body = b'{"status":"CUTOVER_LOCKED"}'
            self._headers(200, len(body))
        else:
            body = b'{"status":"CUTOVER_LOCKED","detail":"runtime_not_enabled"}'
            self._headers(503, len(body))
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write('cutover-lock ' + fmt % args + '\n')

ThreadingHTTPServer(('0.0.0.0', int(os.environ.get('PORT','10000'))), Handler).serve_forever()
