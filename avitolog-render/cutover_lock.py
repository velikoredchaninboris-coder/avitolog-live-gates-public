import os, sys, time, base64, subprocess, urllib.request, urllib.error
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = os.environ.get('CUTOVER_LOCK', '1') != '0'
ROOT = Path(__file__).resolve().parent
PORT = os.environ.get('PORT', '10000')
# live UI layout patch channel verified

def _request(path, headers=None, method='GET', data=None, timeout=5):
    req=urllib.request.Request(
        f'http://127.0.0.1:{PORT}{path}',
        headers=headers or {},
        method=method,
        data=data,
    )
    try:
        with urllib.request.urlopen(req,timeout=timeout) as r:
            return r.status, r.read(1024)
    except urllib.error.HTTPError as e:
        return e.code, e.read(1024)

def _layout_inspect():
    try:
        ui=ROOT/'src'/'frontend'/'runtime'/'index.html'
        if not ui.is_file():
            print('LAYOUT_INSPECT ui_missing', flush=True)
            return
        compact=' '.join(ui.read_text(encoding='utf-8').split())
        for needle in ('now-flow','guide','sidebar','drawer','panel'):
            i=compact.lower().find(needle)
            if i < 0:
                continue
            snippet=compact[max(0,i-600):min(len(compact),i+1200)]
            print('LAYOUT_INSPECT '+needle+' '+snippet, flush=True)
    except Exception as exc:
        print('LAYOUT_INSPECT_FAIL '+type(exc).__name__, flush=True)

def _runtime_selftest(proc):
    deadline=time.time()+30
    last=None
    while time.time()<deadline:
        if proc.poll() is not None:
            raise RuntimeError('RUNTIME_EXITED_BEFORE_SELFTEST')
        try:
            status,_=_request('/healthz',timeout=2)
            if status==200:
                break
            last=f'healthz:{status}'
        except Exception as exc:
            last=type(exc).__name__
        time.sleep(0.5)
    else:
        raise RuntimeError('RUNTIME_HEALTH_TIMEOUT:'+str(last))

    status,body=_request('/readyz',timeout=10)
    if status!=200 or b'"ready"' not in body:
        raise RuntimeError(f'READYZ_FAIL:{status}')

    # Negative boundary: unauthenticated UI must stay closed.
    status,_=_request('/ui/',timeout=5)
    if status!=401:
        raise RuntimeError(f'UI_UNAUTH_EXPECTED_401_GOT:{status}')

    user=os.environ.get('PILOT_BASIC_USER','')
    password=os.environ.get('PILOT_BASIC_PASSWORD','')
    if not user or not password:
        raise RuntimeError('PILOT_BASIC_AUTH_MISSING')
    basic=base64.b64encode(f'{user}:{password}'.encode()).decode()
    basic_headers={'Authorization':'Basic '+basic}
    status,_=_request('/pilot/status',headers=basic_headers,timeout=10)
    if status!=200:
        raise RuntimeError(f'BASIC_AUTH_SELFTEST_FAIL:{status}')
    status,ui_body=_request('/ui/',headers=basic_headers,timeout=10)
    if status!=200:
        raise RuntimeError(f'UI_AUTH_SELFTEST_FAIL:{status}')
    if b'<html' not in ui_body.lower() and b'<!doctype' not in ui_body.lower():
        raise RuntimeError('UI_HTML_MARKER_MISSING')

    owner=os.environ.get('OWNER_API_TOKEN','')
    if not owner:
        raise RuntimeError('OWNER_API_TOKEN_MISSING')
    status,_=_request(
        '/v1/lots/__cutover_selftest_missing__',
        headers={'Authorization':'Bearer '+owner},
        timeout=10,
    )
    if status!=404:
        raise RuntimeError(f'OWNER_BEARER_SELFTEST_FAIL:{status}')

    print('AVITOLOG_RUNTIME_SELFTEST_OK readyz=200 basic=200 ui=200 owner_auth=accepted unauth_ui=401', flush=True)

if not LOCK:
    _layout_inspect()
    backend = ROOT / 'src' / 'backend' / 'runtime'
    if not backend.is_dir():
        raise SystemExit('BACKEND_RUNTIME_MISSING')
    cmd=[sys.executable,'-m','uvicorn','app.main:app','--host','0.0.0.0','--port',PORT]
    proc=subprocess.Popen(cmd,cwd=str(backend),env=os.environ.copy())
    try:
        _runtime_selftest(proc)
    except Exception as exc:
        print('AVITOLOG_RUNTIME_SELFTEST_FAIL '+type(exc).__name__+':'+str(exc), file=sys.stderr, flush=True)
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        raise SystemExit(1)
    raise SystemExit(proc.wait())

class Handler(BaseHTTPRequestHandler):
    def _headers(self, status, length=0):
        self.send_response(status)
        self.send_header('Content-Type','application/json')
        self.send_header('Cache-Control','no-store')
        self.send_header('Content-Length',str(length))
        self.end_headers()

    def do_HEAD(self):
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

ThreadingHTTPServer(('0.0.0.0', int(PORT)), Handler).serve_forever()
