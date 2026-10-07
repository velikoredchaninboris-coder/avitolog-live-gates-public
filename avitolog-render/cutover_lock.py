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
    def do_GET(self):
        if self.path in {'/healthz', '/health'}:
            body = b'{"status":"CUTOVER_LOCKED"}'
            self.send_response(200)
        else:
            body = b'{"status":"CUTOVER_LOCKED","detail":"runtime_not_enabled"}'
            self.send_response(503)
        self.send_header('Content-Type','application/json')
        self.send_header('Cache-Control','no-store')
        self.send_header('Content-Length',str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *args):
        sys.stderr.write('cutover-lock ' + fmt % args + '\n')

ThreadingHTTPServer(('0.0.0.0', int(os.environ.get('PORT','10000'))), Handler).serve_forever()
