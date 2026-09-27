#!/usr/bin/env bash
set -euo pipefail

OUT="avito-live-infra/out/oidc-mfa-v2"
rm -rf "$OUT"
mkdir -p "$OUT"
PHASE="$OUT/phases.log"
phase(){ printf '%s\n' "$1" | tee -a "$PHASE"; }

if [ -n "${JAVA_HOME_21_X64:-}" ]; then
  export JAVA_HOME="$JAVA_HOME_21_X64"
  export PATH="$JAVA_HOME/bin:$PATH"
fi
java -version 2>"$OUT/java-version.txt"

KC_VERSION="26.7.4"
KC_SHA="04823c336b797a7e18889a44262a7a64e6bf624cbbcc518c85e2622176ff2eee"
KC_URL="https://github.com/keycloak/keycloak/releases/download/${KC_VERSION}/keycloak-${KC_VERSION}.tar.gz"

phase "download:start"
curl -fL --retry 3 --retry-delay 2 -o /tmp/keycloak.tar.gz "$KC_URL"
echo "$KC_SHA  /tmp/keycloak.tar.gz" | sha256sum -c -
rm -rf /tmp/keycloak
mkdir -p /tmp/keycloak
tar -xzf /tmp/keycloak.tar.gz -C /tmp/keycloak --strip-components=1
/tmp/keycloak/bin/kc.sh --version | tee "$OUT/keycloak-version.txt"
phase "download:ok"

# All credentials are generated inside this ephemeral runner only.
ADMIN_PASS="$(openssl rand -hex 24)"
USER_PASS="$(openssl rand -hex 24)"
OTP_SECRET="$(openssl rand -hex 20)"
export ADMIN_PASS USER_PASS OTP_SECRET

phase "realm-json:start"
mkdir -p /tmp/keycloak/data/import
python3 - <<'PY'
import json,os
otp=os.environ["OTP_SECRET"]
realm={
 "realm":"avitolog",
 "enabled":True,
 "sslRequired":"none",
 "accessTokenLifespan":300,
 "ssoSessionIdleTimeout":300,
 "ssoSessionMaxLifespan":900,
 "otpPolicyType":"totp",
 "otpPolicyAlgorithm":"HmacSHA1",
 "otpPolicyDigits":6,
 "otpPolicyLookAheadWindow":1,
 "otpPolicyPeriod":30,
 "clients":[{
   "clientId":"avitolog-ci",
   "name":"AVITOLOG CI synthetic client",
   "enabled":True,
   "publicClient":True,
   "directAccessGrantsEnabled":True,
   "standardFlowEnabled":True,
   "redirectUris":["http://127.0.0.1/*"]
 }],
 "users":[{
   "username":"mfa-user",
   "enabled":True,
   "emailVerified":True,
   "totp":True,
   "credentials":[{
     "type":"otp",
     "userLabel":"AVITOLOG CI TOTP",
     "secretData":json.dumps({"value":otp},separators=(",",":")),
     "credentialData":json.dumps({
       "digits":6,"counter":0,"period":30,"algorithm":"HmacSHA1","subType":"totp"
     },separators=(",",":"))
   }]
 }]
}
with open("/tmp/keycloak/data/import/avitolog-realm.json","w") as f:
    json.dump(realm,f)
PY
phase "realm-json:ok"

export KC_BOOTSTRAP_ADMIN_USERNAME=avitolog-admin
export KC_BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PASS"
cd /tmp/keycloak
nohup bin/kc.sh start-dev --http-port=8080 --import-realm > /tmp/keycloak.log 2>&1 &
KC_PID=$!
cleanup(){
  cp /tmp/keycloak.log "$GITHUB_WORKSPACE/$OUT/keycloak.log" >/dev/null 2>&1 || true
  kill "$KC_PID" >/dev/null 2>&1 || true
  wait "$KC_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cd "$GITHUB_WORKSPACE"

DISCOVERY_URL="http://127.0.0.1:8080/realms/avitolog/.well-known/openid-configuration"
phase "keycloak-readiness:start"
for i in $(seq 1 120); do
  if curl -fsS "$DISCOVERY_URL" >/tmp/discovery.json; then
    break
  fi
  if ! kill -0 "$KC_PID" >/dev/null 2>&1; then
    cp /tmp/keycloak.log "$OUT/keycloak.log" || true
    phase "keycloak-readiness:process-exited"
    exit 1
  fi
  sleep 1
done
test -s /tmp/discovery.json
cp /tmp/discovery.json "$OUT/discovery.json"
phase "keycloak-readiness:ok"

phase "admin-login:start"
cd /tmp/keycloak
bin/kcadm.sh config credentials   --server http://127.0.0.1:8080   --realm master   --user avitolog-admin   --password "$ADMIN_PASS" >/dev/null
phase "admin-login:ok"

USER_ID="$(bin/kcadm.sh get users -r avitolog -q username=mfa-user | jq -r '.[0].id')"
test -n "$USER_ID" && test "$USER_ID" != "null"
phase "user-lookup:ok"

bin/kcadm.sh set-password -r avitolog   --userid "$USER_ID"   --new-password "$USER_PASS"
bin/kcadm.sh update "users/$USER_ID" -r avitolog -s enabled=true -s emailVerified=true -s totp=true -s 'requiredActions=[]' >/dev/null
bin/kcadm.sh get "users/$USER_ID" -r avitolog | jq '{enabled,emailVerified,totp,requiredActions}' > "$GITHUB_WORKSPACE/$OUT/user-state.json"
test "$(jq -r '.enabled' "$GITHUB_WORKSPACE/$OUT/user-state.json")" = "true"
test "$(jq -r '.totp' "$GITHUB_WORKSPACE/$OUT/user-state.json")" = "true"
test "$(jq '.requiredActions|length' "$GITHUB_WORKSPACE/$OUT/user-state.json")" = "0"
phase "password-set:ok"

CRED_TYPES="$(bin/kcadm.sh get "users/$USER_ID/credentials" -r avitolog | jq -r '.[].type' | sort -u)"
printf '%s\n' "$CRED_TYPES" > "$GITHUB_WORKSPACE/$OUT/credential-types.txt"
grep -qx 'otp' <<<"$CRED_TYPES"
grep -qx 'password' <<<"$CRED_TYPES"
phase "credential-types:password+otp"

cd "$GITHUB_WORKSPACE"
TOKEN_URL="http://127.0.0.1:8080/realms/avitolog/protocol/openid-connect/token"
JWKS_URI="$(jq -r .jwks_uri /tmp/discovery.json)"
curl -fsS "$JWKS_URI" >/tmp/jwks.json

cat >/tmp/TotpGen.java <<'JAVA'
import org.keycloak.models.utils.TimeBasedOTP;
public class TotpGen {
  public static void main(String[] args) {
    System.out.print(new TimeBasedOTP().generateTOTP(args[0]));
  }
}
JAVA
KC_CP="$(find /tmp/keycloak/lib -type f -name '*.jar' -print | paste -sd: -)"
test -n "$KC_CP"
javac -cp "$KC_CP" /tmp/TotpGen.java
totp_now(){ java -cp "/tmp:$KC_CP" TotpGen "$1"; }

phase "password-only-negative:start"
CODE_NO_OTP="$(curl -sS -o /tmp/no-otp.json -w '%{http_code}' -X POST "$TOKEN_URL"   -H 'Content-Type: application/x-www-form-urlencoded'   --data-urlencode 'client_id=avitolog-ci'   --data-urlencode 'grant_type=password'   --data-urlencode 'username=mfa-user'   --data-urlencode "password=$USER_PASS"   --data-urlencode 'scope=openid')"
printf '%s\n' "$CODE_NO_OTP" > "$OUT/password-only-http-code.txt"
jq '{error,error_description}' /tmp/no-otp.json > "$OUT/password-only-error.json"
test "$CODE_NO_OTP" = "400"
test "$(jq -r '.error' /tmp/no-otp.json)" = "invalid_grant"
phase "password-only-negative:ok"

TOTP1="$(totp_now "$OTP_SECRET")"
WRONG="$(python3 -c 'import sys; print(f"{(int(sys.argv[1])+1)%1000000:06d}")' "$TOTP1")"
phase "wrong-totp-negative:start"
CODE_WRONG="$(curl -sS -o /tmp/wrong.json -w '%{http_code}' -X POST "$TOKEN_URL"   -H 'Content-Type: application/x-www-form-urlencoded'   --data-urlencode 'client_id=avitolog-ci'   --data-urlencode 'grant_type=password'   --data-urlencode 'username=mfa-user'   --data-urlencode "password=$USER_PASS"   --data-urlencode "totp=$WRONG"   --data-urlencode 'scope=openid')"
printf '%s\n' "$CODE_WRONG" > "$OUT/wrong-totp-http-code.txt"
jq '{error,error_description}' /tmp/wrong.json > "$OUT/wrong-totp-error.json"
test "$CODE_WRONG" = "400"
test "$(jq -r '.error' /tmp/wrong.json)" = "invalid_grant"
phase "wrong-totp-negative:ok"

phase "correct-totp-login-1:start"
CODE_OK1="$(curl -sS -o /tmp/token1.json -w '%{http_code}' -X POST "$TOKEN_URL"   -H 'Content-Type: application/x-www-form-urlencoded'   --data-urlencode 'client_id=avitolog-ci'   --data-urlencode 'grant_type=password'   --data-urlencode 'username=mfa-user'   --data-urlencode "password=$USER_PASS"   --data-urlencode "totp=$TOTP1"   --data-urlencode 'scope=openid')"
printf '%s\n' "$CODE_OK1" > "$OUT/correct-totp-1-http-code.txt"
if [ "$CODE_OK1" != "200" ]; then
  jq '{error,error_description}' /tmp/token1.json > "$OUT/correct-totp-1-error.json" || true
  exit 2
fi
jq -e '.access_token and .refresh_token' /tmp/token1.json >/dev/null
phase "correct-totp-login-1:ok"

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

jq -r .access_token /tmp/token1.json >/tmp/access1.jwt
python3 /tmp/decode_jwt.py /tmp/access1.jwt /tmp/token1-claims.json /tmp/token1-header.json /tmp/sign1.txt /tmp/sig1.bin
KID1="$(jq -r .kid /tmp/token1-header.json)"
X5C1="$(jq -r --arg k "$KID1" '.keys[]|select(.kid==$k)|.x5c[0]' /tmp/jwks.json)"
test -n "$X5C1" && test "$X5C1" != "null"
printf '%s' "$X5C1" | base64 -d >/tmp/cert1.der
openssl x509 -inform DER -in /tmp/cert1.der -pubkey -noout >/tmp/pub1.pem
openssl dgst -sha256 -verify /tmp/pub1.pem -signature /tmp/sig1.bin /tmp/sign1.txt | tee "$OUT/jwt-signature-verify-1.txt"
grep -q 'Verified OK' "$OUT/jwt-signature-verify-1.txt"
phase "jwt-signature-1:ok"

SLEEP_FOR="$(python3 -c 'import time; print(max(2,31-(int(time.time())%30)))')"
sleep "$SLEEP_FOR"
TOTP2="$(totp_now "$OTP_SECRET")"
test "$TOTP2" != "$TOTP1"

phase "correct-totp-login-2:start"
CODE_OK2="$(curl -sS -o /tmp/token2.json -w '%{http_code}' -X POST "$TOKEN_URL"   -H 'Content-Type: application/x-www-form-urlencoded'   --data-urlencode 'client_id=avitolog-ci'   --data-urlencode 'grant_type=password'   --data-urlencode 'username=mfa-user'   --data-urlencode "password=$USER_PASS"   --data-urlencode "totp=$TOTP2"   --data-urlencode 'scope=openid')"
printf '%s\n' "$CODE_OK2" > "$OUT/correct-totp-2-http-code.txt"
if [ "$CODE_OK2" != "200" ]; then
  jq '{error,error_description}' /tmp/token2.json > "$OUT/correct-totp-2-error.json" || true
  exit 3
fi
jq -e '.access_token and .refresh_token' /tmp/token2.json >/dev/null
phase "correct-totp-login-2:ok"

jq -r .access_token /tmp/token2.json >/tmp/access2.jwt
python3 /tmp/decode_jwt.py /tmp/access2.jwt /tmp/token2-claims.json /tmp/token2-header.json /tmp/sign2.txt /tmp/sig2.bin
KID2="$(jq -r .kid /tmp/token2-header.json)"
X5C2="$(jq -r --arg k "$KID2" '.keys[]|select(.kid==$k)|.x5c[0]' /tmp/jwks.json)"
test -n "$X5C2" && test "$X5C2" != "null"
printf '%s' "$X5C2" | base64 -d >/tmp/cert2.der
openssl x509 -inform DER -in /tmp/cert2.der -pubkey -noout >/tmp/pub2.pem
openssl dgst -sha256 -verify /tmp/pub2.pem -signature /tmp/sig2.bin /tmp/sign2.txt | tee "$OUT/jwt-signature-verify-2.txt"
grep -q 'Verified OK' "$OUT/jwt-signature-verify-2.txt"
phase "jwt-signature-2:ok"

cat >/tmp/report.py <<'PY'
import json,sys,hashlib
out,disc,jwks,c1,c2,code_no,code_wrong,code1,code2=sys.argv[1:]
d=json.load(open(disc)); j=json.load(open(jwks)); a=json.load(open(c1)); b=json.load(open(c2))
issuer='http://127.0.0.1:8080/realms/avitolog'
report={
  'gate':'M21B_KEYCLOAK_OIDC_MFA_LIVE_MECHANICS_V2',
  'keycloak_version':'26.7.4',
  'release_tarball_sha256':'04823c336b797a7e18889a44262a7a64e6bf624cbbcc518c85e2622176ff2eee',
  'discovery_issuer_match':d.get('issuer')==issuer,
  'jwks_uri_match':d.get('jwks_uri')==issuer+'/protocol/openid-connect/certs',
  'jwks_key_count':len(j.get('keys') or []),
  'password_only_http_code':int(code_no),
  'wrong_totp_http_code':int(code_wrong),
  'correct_totp_1_http_code':int(code1),
  'correct_totp_2_http_code':int(code2),
  'password_only_denied':code_no=='400',
  'wrong_totp_denied':code_wrong=='400',
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
  'token1_auth_time':a.get('auth_time'),
  'token2_auth_time':b.get('auth_time'),
  'token1_iat':a.get('iat'),
  'token2_iat':b.get('iat'),
  'second_mfa_login_newer':isinstance(a.get('iat'),int) and isinstance(b.get('iat'),int) and b.get('iat')>a.get('iat'),
  'tokens_exported':False,
  'password_exported':False,
  'totp_secret_exported':False,
  'persistent_external_idp':False
}
checks=[
 report['discovery_issuer_match'],report['jwks_uri_match'],report['jwks_key_count']>0,
 report['password_only_denied'],report['wrong_totp_denied'],
 report['correct_totp_1_http_code']==200,report['correct_totp_2_http_code']==200,
 report['mfa_token1_signature_verified'],report['mfa_token2_signature_verified'],
 report['token1_issuer_match'],report['token2_issuer_match'],
 report['token1_subject_present'],report['token2_subject_present'],
 report['token1_azp']=='avitolog-ci',report['token2_azp']=='avitolog-ci',
 report['second_mfa_login_newer'],
 not report['tokens_exported'],not report['password_exported'],not report['totp_secret_exported']
]
report['status']='PASS' if all(checks) else 'FAIL'
json.dump(report,open(out,'w'),ensure_ascii=False,indent=2)
print(json.dumps(report,ensure_ascii=False,indent=2))
if report['status']!='PASS': raise SystemExit(4)
PY

python3 /tmp/report.py   "$OUT/report.json" /tmp/discovery.json /tmp/jwks.json   /tmp/token1-claims.json /tmp/token2-claims.json   "$CODE_NO_OTP" "$CODE_WRONG" "$CODE_OK1" "$CODE_OK2"

# Redaction gate against dynamically generated credentials/tokens.
for secret in "$ADMIN_PASS" "$USER_PASS" "$OTP_SECRET"; do
  if grep -R -F "$secret" "$OUT" >/dev/null 2>&1; then
    echo "Credential material leaked to artifact" >&2
    exit 5
  fi
done
if grep -R -E 'eyJ[A-Za-z0-9_-]{40,}' "$OUT" >/dev/null 2>&1; then
  echo "JWT-like token leaked to artifact" >&2
  exit 6
fi
phase "redaction-gate:ok"

rm -f /tmp/token1.json /tmp/token2.json /tmp/access1.jwt /tmp/access2.jwt /tmp/sign1.txt /tmp/sign2.txt /tmp/sig1.bin /tmp/sig2.bin
