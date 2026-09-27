#!/usr/bin/env bash
set -euo pipefail

OUT="avito-live-infra/out/oidc-mfa"
rm -rf "$OUT"
mkdir -p "$OUT"

if [ -n "${JAVA_HOME_21_X64:-}" ]; then
  export JAVA_HOME="$JAVA_HOME_21_X64"
  export PATH="$JAVA_HOME/bin:$PATH"
fi
java -version 2>"$OUT/java-version.txt"

KC_VERSION="26.7.4"
KC_SHA="04823c336b797a7e18889a44262a7a64e6bf624cbbcc518c85e2622176ff2eee"
KC_URL="https://github.com/keycloak/keycloak/releases/download/${KC_VERSION}/keycloak-${KC_VERSION}.tar.gz"
curl -fL --retry 3 --retry-delay 2 -o /tmp/keycloak.tar.gz "$KC_URL"
echo "$KC_SHA  /tmp/keycloak.tar.gz" | sha256sum -c -
rm -rf /tmp/keycloak
mkdir -p /tmp/keycloak
tar -xzf /tmp/keycloak.tar.gz -C /tmp/keycloak --strip-components=1
/tmp/keycloak/bin/kc.sh --version | tee "$OUT/keycloak-version.txt"

mkdir -p /tmp/keycloak/data/import
cat > /tmp/keycloak/data/import/avitolog-realm.json <<'JSON'
{
  "realm": "avitolog",
  "enabled": true,
  "sslRequired": "none",
  "accessTokenLifespan": 300,
  "ssoSessionIdleTimeout": 300,
  "ssoSessionMaxLifespan": 900,
  "otpPolicyType": "totp",
  "otpPolicyAlgorithm": "HmacSHA1",
  "otpPolicyDigits": 6,
  "otpPolicyLookAheadWindow": 1,
  "otpPolicyPeriod": 30,
  "clients": [
    {
      "clientId": "avitolog-ci",
      "name": "AVITOLOG CI synthetic client",
      "enabled": true,
      "publicClient": true,
      "directAccessGrantsEnabled": true,
      "standardFlowEnabled": true,
      "redirectUris": ["http://127.0.0.1/*"]
    }
  ],
  "users": [
    {
      "username": "mfa-user",
      "enabled": true,
      "emailVerified": true,
      "credentials": [
        {
          "type": "password",
          "value": "AVITOLOG_CI_SYNTHETIC_PASSWORD_2026",
          "temporary": false
        },
        {
          "type": "otp",
          "userLabel": "AVITOLOG CI TOTP",
          "secretData": "{\"value\":\"JBSWY3DPEHPK3PXP\"}",
          "credentialData": "{\"subType\":\"totp\",\"digits\":6,\"counter\":0,\"period\":30,\"algorithm\":\"HmacSHA1\"}"
        }
      ]
    }
  ]
}
JSON

export KC_BOOTSTRAP_ADMIN_USERNAME=avitolog-admin
export KC_BOOTSTRAP_ADMIN_PASSWORD=AVITOLOG_CI_SYNTHETIC_ADMIN_2026
cd /tmp/keycloak
nohup bin/kc.sh start-dev --http-port=8080 --import-realm > /tmp/keycloak.log 2>&1 &
KC_PID=$!
cleanup(){ kill "$KC_PID" >/dev/null 2>&1 || true; wait "$KC_PID" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cd "$GITHUB_WORKSPACE"

DISCOVERY_URL="http://127.0.0.1:8080/realms/avitolog/.well-known/openid-configuration"
for i in $(seq 1 120); do
  if curl -fsS "$DISCOVERY_URL" >/tmp/discovery.json; then break; fi
  sleep 1
done
if ! test -s /tmp/discovery.json; then
  tail -200 /tmp/keycloak.log
  exit 1
fi
cp /tmp/discovery.json "$OUT/discovery.json"
TOKEN_URL="http://127.0.0.1:8080/realms/avitolog/protocol/openid-connect/token"
PASSWORD="AVITOLOG_CI_SYNTHETIC_PASSWORD_2026"
SECRET="JBSWY3DPEHPK3PXP"
JWKS_URI="$(jq -r .jwks_uri /tmp/discovery.json)"
curl -fsS "$JWKS_URI" >/tmp/jwks.json

cat >/tmp/totp.py <<'PY'
import base64,hmac,hashlib,struct,time,sys
key=base64.b32decode(sys.argv[1],casefold=True)
counter=int(time.time())//30
msg=struct.pack('>Q',counter)
h=hmac.new(key,msg,hashlib.sha1).digest()
o=h[-1]&15
n=(struct.unpack('>I',h[o:o+4])[0]&0x7fffffff)%1000000
print(f"{n:06d}")
PY

CODE_NO_OTP="$(curl -sS -o /tmp/no-otp.json -w '%{http_code}' -X POST "$TOKEN_URL"   -H 'Content-Type: application/x-www-form-urlencoded'   --data-urlencode 'client_id=avitolog-ci'   --data-urlencode 'grant_type=password'   --data-urlencode 'username=mfa-user'   --data-urlencode "password=$PASSWORD"   --data-urlencode 'scope=openid')"
test "$CODE_NO_OTP" = "401"

TOTP1="$(python3 /tmp/totp.py "$SECRET")"
WRONG="$(python3 -c 'import sys; print(f"{(int(sys.argv[1])+1)%1000000:06d}")' "$TOTP1")"
CODE_WRONG="$(curl -sS -o /tmp/wrong.json -w '%{http_code}' -X POST "$TOKEN_URL"   -H 'Content-Type: application/x-www-form-urlencoded'   --data-urlencode 'client_id=avitolog-ci'   --data-urlencode 'grant_type=password'   --data-urlencode 'username=mfa-user'   --data-urlencode "password=$PASSWORD"   --data-urlencode "totp=$WRONG"   --data-urlencode 'scope=openid')"
test "$CODE_WRONG" = "401"

curl -fsS -X POST "$TOKEN_URL"   -H 'Content-Type: application/x-www-form-urlencoded'   --data-urlencode 'client_id=avitolog-ci'   --data-urlencode 'grant_type=password'   --data-urlencode 'username=mfa-user'   --data-urlencode "password=$PASSWORD"   --data-urlencode "totp=$TOTP1"   --data-urlencode 'scope=openid' >/tmp/token1.json
jq -e '.access_token and .refresh_token' /tmp/token1.json >/dev/null
jq -r .access_token /tmp/token1.json >/tmp/access1.jwt

cat >/tmp/decode_jwt.py <<'PY'
import base64,json,sys
jwt=open(sys.argv[1]).read().strip()
h,p,s=jwt.split('.')
dec=lambda x: base64.urlsafe_b64decode(x+'='*((4-len(x)%4)%4))
json.dump(json.loads(dec(p)),open(sys.argv[2],'w'),indent=2)
json.dump(json.loads(dec(h)),open(sys.argv[3],'w'),indent=2)
open(sys.argv[4],'wb').write((h+'.'+p).encode())
open(sys.argv[5],'wb').write(dec(s))
PY
python3 /tmp/decode_jwt.py /tmp/access1.jwt /tmp/token1-claims.json /tmp/token1-header.json /tmp/sign1.txt /tmp/sig1.bin
KID1="$(jq -r .kid /tmp/token1-header.json)"
X5C1="$(jq -r --arg k "$KID1" '.keys[]|select(.kid==$k)|.x5c[0]' /tmp/jwks.json)"
test -n "$X5C1" && test "$X5C1" != "null"
printf '%s' "$X5C1" | base64 -d >/tmp/cert1.der
openssl x509 -inform DER -in /tmp/cert1.der -pubkey -noout >/tmp/pub1.pem
openssl dgst -sha256 -verify /tmp/pub1.pem -signature /tmp/sig1.bin /tmp/sign1.txt | tee "$OUT/jwt-signature-verify-1.txt"
grep -q 'Verified OK' "$OUT/jwt-signature-verify-1.txt"

SLEEP_FOR="$(python3 -c 'import time; print(max(2,31-(int(time.time())%30)))')"
sleep "$SLEEP_FOR"
TOTP2="$(python3 /tmp/totp.py "$SECRET")"
test "$TOTP2" != "$TOTP1"

curl -fsS -X POST "$TOKEN_URL"   -H 'Content-Type: application/x-www-form-urlencoded'   --data-urlencode 'client_id=avitolog-ci'   --data-urlencode 'grant_type=password'   --data-urlencode 'username=mfa-user'   --data-urlencode "password=$PASSWORD"   --data-urlencode "totp=$TOTP2"   --data-urlencode 'scope=openid' >/tmp/token2.json
jq -e '.access_token and .refresh_token' /tmp/token2.json >/dev/null
jq -r .access_token /tmp/token2.json >/tmp/access2.jwt
python3 /tmp/decode_jwt.py /tmp/access2.jwt /tmp/token2-claims.json /tmp/token2-header.json /tmp/sign2.txt /tmp/sig2.bin
KID2="$(jq -r .kid /tmp/token2-header.json)"
X5C2="$(jq -r --arg k "$KID2" '.keys[]|select(.kid==$k)|.x5c[0]' /tmp/jwks.json)"
printf '%s' "$X5C2" | base64 -d >/tmp/cert2.der
openssl x509 -inform DER -in /tmp/cert2.der -pubkey -noout >/tmp/pub2.pem
openssl dgst -sha256 -verify /tmp/pub2.pem -signature /tmp/sig2.bin /tmp/sign2.txt | tee "$OUT/jwt-signature-verify-2.txt"
grep -q 'Verified OK' "$OUT/jwt-signature-verify-2.txt"

cat >/tmp/report.py <<'PY'
import json,sys
out,nootp,wrong,disc,jwks,c1,c2=sys.argv[1:]
d=json.load(open(disc)); j=json.load(open(jwks)); a=json.load(open(c1)); b=json.load(open(c2))
issuer='http://127.0.0.1:8080/realms/avitolog'
report={
  'gate':'M21B_KEYCLOAK_OIDC_MFA_LIVE_MECHANICS',
  'keycloak_version':'26.7.4',
  'release_tarball_sha256':'04823c336b797a7e18889a44262a7a64e6bf624cbbcc518c85e2622176ff2eee',
  'discovery_issuer_match':d.get('issuer')==issuer,
  'jwks_uri_match':d.get('jwks_uri')==issuer+'/protocol/openid-connect/certs',
  'jwks_key_count':len(j.get('keys') or []),
  'password_only_denied':nootp=='401',
  'wrong_totp_denied':wrong=='401',
  'mfa_token1_signature_verified':True,
  'mfa_token2_signature_verified':True,
  'token1_issuer_match':a.get('iss')==issuer,
  'token2_issuer_match':b.get('iss')==issuer,
  'token1_subject_present':bool(a.get('sub')),
  'token2_subject_present':bool(b.get('sub')),
  'token1_azp':a.get('azp'),
  'token2_azp':b.get('azp'),
  'token1_acr':a.get('acr'),
  'token2_acr':b.get('acr'),
  'token1_iat':a.get('iat'),
  'token2_iat':b.get('iat'),
  'reauth_second_login_newer':isinstance(a.get('iat'),int) and isinstance(b.get('iat'),int) and b.get('iat')>a.get('iat'),
  'session_state_distinct':bool(a.get('session_state')) and bool(b.get('session_state')) and a.get('session_state')!=b.get('session_state'),
  'tokens_exported':False,
  'totp_secret_exported':False,
  'persistent_external_idp':False
}
checks=[
 report['discovery_issuer_match'],report['jwks_uri_match'],report['jwks_key_count']>0,
 report['password_only_denied'],report['wrong_totp_denied'],
 report['mfa_token1_signature_verified'],report['mfa_token2_signature_verified'],
 report['token1_issuer_match'],report['token2_issuer_match'],
 report['token1_subject_present'],report['token2_subject_present'],
 report['token1_azp']=='avitolog-ci',report['token2_azp']=='avitolog-ci',
 report['reauth_second_login_newer'],report['session_state_distinct'],
 not report['tokens_exported'],not report['totp_secret_exported']
]
report['status']='PASS' if all(checks) else 'FAIL'
json.dump(report,open(out,'w'),ensure_ascii=False,indent=2)
print(json.dumps(report,ensure_ascii=False,indent=2))
if report['status']!='PASS': raise SystemExit(2)
PY
python3 /tmp/report.py "$OUT/report.json" "$CODE_NO_OTP" "$CODE_WRONG" /tmp/discovery.json /tmp/jwks.json /tmp/token1-claims.json /tmp/token2-claims.json

# Keep artifacts redacted: no tokens, passwords or TOTP secret.
if grep -R -E 'eyJ[A-Za-z0-9_-]{20,}|JBSWY3DPEHPK3PXP|AVITOLOG_CI_SYNTHETIC_PASSWORD' "$OUT"; then
  echo "Sensitive synthetic credential material leaked to artifact" >&2
  exit 3
fi
