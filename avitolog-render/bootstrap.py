from pathlib import Path
import os, base64, hashlib, zipfile, shutil, io, json
from cryptography.fernet import Fernet, InvalidToken

ROOT = Path(__file__).resolve().parent
META = json.loads((ROOT / 'meta.json').read_text(encoding='utf-8'))
EXPECTED_SOURCE_SHA = META['source_sha256']
EXPECTED_CIPHER_SHA = META['ciphertext_sha256']
EXPECTED_PARTS = int(META['part_count'])

parts = sorted(ROOT.glob('cipher.b64.part-*'))
if len(parts) != EXPECTED_PARTS:
    raise SystemExit('CIPHER_PART_COUNT_MISMATCH')

try:
    cipher = base64.b64decode(''.join(p.read_text(encoding='ascii') for p in parts), validate=True)
except Exception as exc:
    raise SystemExit('CIPHER_BASE64_INVALID') from exc

if hashlib.sha256(cipher).hexdigest() != EXPECTED_CIPHER_SHA:
    raise SystemExit('CIPHERTEXT_INTEGRITY_FAIL')

key = os.environ.get('AVITOLOG_FERNET_KEY', '').encode('ascii')
if not key:
    raise SystemExit('FERNET_KEY_MISSING')
try:
    data = Fernet(key).decrypt(cipher)
except (ValueError, InvalidToken) as exc:
    raise SystemExit('SOURCE_DECRYPT_FAIL') from exc

if hashlib.sha256(data).hexdigest() != EXPECTED_SOURCE_SHA:
    raise SystemExit('SOURCE_ZIP_INTEGRITY_FAIL')

target = ROOT / 'src'
shutil.rmtree(target, ignore_errors=True)
target.mkdir()
with zipfile.ZipFile(io.BytesIO(data)) as z:
    root = target.resolve()
    for member in z.infolist():
        dest = (target / member.filename).resolve()
        if dest != root and root not in dest.parents:
            raise SystemExit('ZIP_PATH_TRAVERSAL:' + member.filename)
    z.extractall(target)

manifest = target / 'SHA256SUMS.txt'
if not manifest.is_file():
    raise SystemExit('INNER_MANIFEST_MISSING')
for line in manifest.read_text(encoding='utf-8').splitlines():
    if not line.strip():
        continue
    digest, rel = line.split('  ', 1)
    path = target / rel
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise SystemExit('INNER_MANIFEST_FAIL:' + rel)

print('AVITOLOG_RENDER_BOOTSTRAP_OK', EXPECTED_SOURCE_SHA)
