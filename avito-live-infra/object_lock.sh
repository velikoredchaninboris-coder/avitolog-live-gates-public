#!/usr/bin/env bash
set -euo pipefail
OUT="avito-live-infra/out/object-lock"
mkdir -p "$OUT"
REL="minio.linux-amd64.RELEASE.2025-09-07T16-13-09Z"
URL="https://github.com/minio/minio/releases/download/RELEASE.2025-09-07T16-13-09Z/$REL"
EXPECTED_SHA256="7c5bd8512c6e966455b1d198209358b2d191c77a83ab377c4073281065fb855f"
curl -fL --retry 3 --retry-delay 2 -o "$REL" "$URL"
echo "$EXPECTED_SHA256  $REL" | sha256sum -c -
chmod +x "$REL"
DIGEST="$(sha256sum "$REL" | awk '{print $1}')"
mkdir -p "$OUT/data"
MINIO_ROOT_USER=ciadmin MINIO_ROOT_PASSWORD=ciadmin123 \
  "./$REL" server "$OUT/data" --address ":9000" --console-address ":9001" >"$OUT/minio.log" 2>&1 &
MINIO_PID=$!
cleanup(){ kill "$MINIO_PID" >/dev/null 2>&1 || true; wait "$MINIO_PID" >/dev/null 2>&1 || true; }
trap cleanup EXIT
for i in $(seq 1 60); do
  curl -fsS http://127.0.0.1:9000/minio/health/live >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS http://127.0.0.1:9000/minio/health/live >/dev/null

command -v aws >/dev/null
export AWS_ACCESS_KEY_ID=ciadmin AWS_SECRET_ACCESS_KEY=ciadmin123 AWS_DEFAULT_REGION=us-east-1
EP="http://127.0.0.1:9000"
aws --endpoint-url "$EP" s3api create-bucket --bucket avitolog-worm --object-lock-enabled-for-bucket >/dev/null
aws --endpoint-url "$EP" s3api put-object-lock-configuration --bucket avitolog-worm \
  --object-lock-configuration '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"COMPLIANCE","Days":1}}}'
printf 'AVITOLOG-WORM-V1\n' > "$OUT/v1.txt"
printf 'AVITOLOG-WORM-V2\n' > "$OUT/v2.txt"
H1="$(sha256sum "$OUT/v1.txt" | awk '{print $1}')"
P1="$(aws --endpoint-url "$EP" s3api put-object --bucket avitolog-worm --key evidence.txt --body "$OUT/v1.txt")"
V1="$(jq -r '.VersionId' <<<"$P1")"
R1="$(aws --endpoint-url "$EP" s3api get-object-retention --bucket avitolog-worm --key evidence.txt --version-id "$V1")"
MODE="$(jq -r '.Retention.Mode' <<<"$R1")"
P2="$(aws --endpoint-url "$EP" s3api put-object --bucket avitolog-worm --key evidence.txt --body "$OUT/v2.txt")"
V2="$(jq -r '.VersionId' <<<"$P2")"
set +e
DEL_ERR="$(aws --endpoint-url "$EP" s3api delete-object --bucket avitolog-worm --key evidence.txt --version-id "$V1" 2>&1)"
DEL_RC=$?
set -e
aws --endpoint-url "$EP" s3api get-object --bucket avitolog-worm --key evidence.txt --version-id "$V1" "$OUT/readback-v1.txt" >/dev/null
H1B="$(sha256sum "$OUT/readback-v1.txt" | awk '{print $1}')"
VERS="$(aws --endpoint-url "$EP" s3api list-object-versions --bucket avitolog-worm --prefix evidence.txt)"
VC="$(jq '[.Versions[]?] | length' <<<"$VERS")"
LOCK="$(aws --endpoint-url "$EP" s3api get-object-lock-configuration --bucket avitolog-worm)"
VER="$(aws --endpoint-url "$EP" s3api get-bucket-versioning --bucket avitolog-worm)"
python3 - "$OUT/report.json" "$DIGEST" "$V1" "$V2" "$MODE" "$DEL_RC" "$H1" "$H1B" "$VC" "$LOCK" "$VER" <<'PY'
import json,sys
out,digest,v1,v2,mode,del_rc,h1,h1b,vc,lock,ver=sys.argv[1:]
r={
 "gate":"M23B_MINIO_OBJECT_LOCK_LIVE_MECHANICS",
 "binary_sha256":digest,
 "bucket_object_lock":json.loads(lock),
 "bucket_versioning":json.loads(ver),
 "v1_version_id_present":bool(v1 and v1!="null"),
 "v2_version_id_present":bool(v2 and v2!="null"),
 "distinct_versions":v1!=v2,
 "retention_mode":mode,
 "specific_version_delete_blocked":int(del_rc)!=0,
 "old_version_readback_hash_match":h1==h1b,
 "version_count":int(vc),
 "persistent_external_target":False
}
r["status"]="PASS" if all([
 r["v1_version_id_present"],r["v2_version_id_present"],r["distinct_versions"],
 r["retention_mode"]=="COMPLIANCE",r["specific_version_delete_blocked"],
 r["old_version_readback_hash_match"],r["version_count"]>=2
]) else "FAIL"
json.dump(r,open(out,"w"),indent=2)
print(json.dumps(r,indent=2))
raise SystemExit(0 if r["status"]=="PASS" else 2)
PY
