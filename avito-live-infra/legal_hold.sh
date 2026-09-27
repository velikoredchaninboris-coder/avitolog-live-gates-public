#!/usr/bin/env bash
set -euo pipefail

OUT="avito-live-infra/out/object-lock"
mkdir -p "$OUT/legalhold-data"
REL="minio.linux-amd64.RELEASE.2025-09-07T16-13-09Z"
URL="https://github.com/minio/minio/releases/download/RELEASE.2025-09-07T16-13-09Z/$REL"
EXPECTED_SHA256="7c5bd8512c6e966455b1d198209358b2d191c77a83ab377c4073281065fb855f"

if [ ! -x "./$REL" ]; then
  curl -fL --retry 3 --retry-delay 2 -o "$REL" "$URL"
  echo "$EXPECTED_SHA256  $REL" | sha256sum -c -
  chmod +x "$REL"
fi

ROOT_USER="m23b$(openssl rand -hex 6)"
ROOT_PASS="$(openssl rand -hex 24)"
MINIO_ROOT_USER="$ROOT_USER" MINIO_ROOT_PASSWORD="$ROOT_PASS" \
  "./$REL" server "$OUT/legalhold-data" --address ":9010" --console-address ":9011" \
  >"$OUT/legalhold-minio.log" 2>&1 &
PID=$!
cleanup(){ kill "$PID" >/dev/null 2>&1 || true; wait "$PID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

for i in $(seq 1 60); do
  curl -fsS http://127.0.0.1:9010/minio/health/live >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS http://127.0.0.1:9010/minio/health/live >/dev/null

export AWS_ACCESS_KEY_ID="$ROOT_USER"
export AWS_SECRET_ACCESS_KEY="$ROOT_PASS"
export AWS_DEFAULT_REGION=us-east-1
EP="http://127.0.0.1:9010"

aws --endpoint-url "$EP" s3api create-bucket --bucket avitolog-legalhold --object-lock-enabled-for-bucket >/dev/null
printf 'AVITOLOG-LEGAL-HOLD\n' > "$OUT/legalhold-object.txt"
PUT="$(aws --endpoint-url "$EP" s3api put-object --bucket avitolog-legalhold --key hold.txt --body "$OUT/legalhold-object.txt")"
VID="$(jq -r '.VersionId' <<<"$PUT")"
test -n "$VID"
test "$VID" != "null"

aws --endpoint-url "$EP" s3api put-object-legal-hold \
  --bucket avitolog-legalhold --key hold.txt --version-id "$VID" \
  --legal-hold '{"Status":"ON"}'
INFO="$(aws --endpoint-url "$EP" s3api get-object-legal-hold \
  --bucket avitolog-legalhold --key hold.txt --version-id "$VID")"
STATUS="$(jq -r '.LegalHold.Status' <<<"$INFO")"
printf '%s\n' "$INFO" > "$OUT/legalhold-info.json"

set +e
aws --endpoint-url "$EP" s3api delete-object \
  --bucket avitolog-legalhold --key hold.txt --version-id "$VID" \
  >"$OUT/legalhold-delete.stdout" 2>"$OUT/legalhold-delete.stderr"
DEL_RC=$?
set -e

python3 - "$OUT/legalhold-report.json" "$VID" "$STATUS" "$DEL_RC" <<'PY'
import json,sys
out,vid,status,rc=sys.argv[1:]
r={
  "gate":"M23B_MINIO_LEGAL_HOLD_LIVE",
  "object_lock_bucket_created":True,
  "version_id_present":bool(vid and vid!="null"),
  "legal_hold_status":status,
  "version_specific_delete_blocked":int(rc)!=0,
  "credentials_generated_at_runtime":True,
  "real_user_data_used":False,
  "persistent_external_target":False,
}
r["status"]="PASS" if (
  r["version_id_present"] and
  r["legal_hold_status"]=="ON" and
  r["version_specific_delete_blocked"]
) else "FAIL"
json.dump(r,open(out,"w"),indent=2)
print(json.dumps(r,indent=2))
raise SystemExit(0 if r["status"]=="PASS" else 2)
PY
