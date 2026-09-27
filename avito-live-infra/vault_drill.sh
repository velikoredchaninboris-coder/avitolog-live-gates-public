#!/usr/bin/env bash
set -euo pipefail
OUT="avito-live-infra/out/vault"
mkdir -p "$OUT"
IMAGE="hashicorp/vault:1.21.4"
docker pull "$IMAGE" >/dev/null
DIGEST="$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE")"
docker run -d --name avito-vault --cap-add=IPC_LOCK -p 8200:8200 \
  -e VAULT_DEV_ROOT_TOKEN_ID=root-ci-token \
  -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 \
  "$IMAGE" server -dev >/dev/null
cleanup(){ docker rm -f avito-vault >/dev/null 2>&1 || true; }
trap cleanup EXIT
for i in $(seq 1 60); do
  curl -fsS http://127.0.0.1:8200/v1/sys/health >/dev/null 2>&1 && break
  sleep 1
done
BASE="http://127.0.0.1:8200/v1"
ROOT="root-ci-token"
HROOT=(-H "X-Vault-Token: $ROOT" -H "Content-Type: application/json")
curl -fsS -X POST "${HROOT[@]}" "$BASE/sys/mounts/avito" -d '{"type":"kv","options":{"version":"2"}}' >/dev/null
POL='path "avito/data/*" { capabilities = ["create","update","read"] }
path "avito/metadata/*" { capabilities = ["read"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self" { capabilities = ["update"] }
path "auth/token/revoke-self" { capabilities = ["update"] }'
curl -fsS -X PUT "${HROOT[@]}" "$BASE/sys/policies/acl/avito-ci" \
  -d "$(jq -n --arg p "$POL" '{policy:$p}')" >/dev/null
curl -fsS -X POST "${HROOT[@]}" "$BASE/sys/auth/approle" -d '{"type":"approle"}' >/dev/null
curl -fsS -X POST "${HROOT[@]}" "$BASE/auth/approle/role/avito-ci" \
  -d '{"token_policies":["avito-ci"],"token_ttl":"60s","token_max_ttl":"120s","secret_id_num_uses":1}' >/dev/null
ROLE_ID="$(curl -fsS "${HROOT[@]}" "$BASE/auth/approle/role/avito-ci/role-id" | jq -r .data.role_id)"
SECRET_ID="$(curl -fsS -X POST "${HROOT[@]}" "$BASE/auth/approle/role/avito-ci/secret-id" | jq -r .data.secret_id)"
LOGIN="$(curl -fsS -X POST -H "Content-Type: application/json" "$BASE/auth/approle/login" \
  -d "$(jq -n --arg r "$ROLE_ID" --arg s "$SECRET_ID" '{role_id:$r,secret_id:$s}')")"
TOKEN="$(jq -r .auth.client_token <<<"$LOGIN")"
TTL0="$(jq -r .auth.lease_duration <<<"$LOGIN")"
RENEWABLE="$(jq -r .auth.renewable <<<"$LOGIN")"
CANARY1="$(openssl rand -hex 16)"
CANARY2="$(openssl rand -hex 16)"
H1="$(printf '%s' "$CANARY1" | sha256sum | awk '{print $1}')"
H2="$(printf '%s' "$CANARY2" | sha256sum | awk '{print $1}')"
HTOK=(-H "X-Vault-Token: $TOKEN" -H "Content-Type: application/json")
curl -fsS -X POST "${HTOK[@]}" "$BASE/avito/data/live-gate" -d "$(jq -n --arg v "$CANARY1" '{data:{canary:$v}}')" >/dev/null
READ1="$(curl -fsS "${HTOK[@]}" "$BASE/avito/data/live-gate" | jq -r .data.data.canary)"
RH1="$(printf '%s' "$READ1" | sha256sum | awk '{print $1}')"
curl -fsS -X POST "${HTOK[@]}" "$BASE/avito/data/live-gate" -d "$(jq -n --arg v "$CANARY2" '{data:{canary:$v}}')" >/dev/null
META="$(curl -fsS "${HTOK[@]}" "$BASE/avito/metadata/live-gate")"
CURVER="$(jq -r .data.current_version <<<"$META")"
READ2="$(curl -fsS "${HTOK[@]}" "$BASE/avito/data/live-gate" | jq -r .data.data.canary)"
RH2="$(printf '%s' "$READ2" | sha256sum | awk '{print $1}')"
RENEW="$(curl -fsS -X POST "${HTOK[@]}" "$BASE/auth/token/renew-self" -d '{}')"
TTL1="$(jq -r .auth.lease_duration <<<"$RENEW")"
curl -fsS -X POST "${HTOK[@]}" "$BASE/auth/token/revoke-self" -d '{}' >/dev/null
set +e
POST_REVOKE_CODE="$(curl -sS -o "$OUT/post_revoke.json" -w '%{http_code}' "${HTOK[@]}" "$BASE/avito/data/live-gate")"
set -e
python3 - "$OUT/report.json" "$DIGEST" "$TTL0" "$TTL1" "$RENEWABLE" "$CURVER" "$H1" "$RH1" "$H2" "$RH2" "$POST_REVOKE_CODE" <<'PY'
import json,sys
out,digest,ttl0,ttl1,renewable,curver,h1,rh1,h2,rh2,code=sys.argv[1:]
r={
 "gate":"M57B_VAULT_LIVE_MECHANICS",
 "image_digest":digest,
 "auth_method":"AppRole",
 "initial_token_ttl_seconds":int(ttl0),
 "renewed_token_ttl_seconds":int(ttl1),
 "renewable":renewable=="true",
 "secret_rotation_current_version":int(curver),
 "v1_readback_hash_match":h1==rh1,
 "v2_readback_hash_match":h2==rh2,
 "secret_rotated":h1!=h2,
 "revoked_token_denied":int(code) in (403,400),
 "persistent_external_vault":False
}
r["status"]="PASS" if all([
 r["renewable"],r["initial_token_ttl_seconds"]>0,r["renewed_token_ttl_seconds"]>0,
 r["secret_rotation_current_version"]==2,r["v1_readback_hash_match"],
 r["v2_readback_hash_match"],r["secret_rotated"],r["revoked_token_denied"]
]) else "FAIL"
json.dump(r,open(out,"w"),indent=2)
print(json.dumps(r,indent=2))
raise SystemExit(0 if r["status"]=="PASS" else 2)
PY
