#!/usr/bin/env bash
set -euo pipefail
OUT="avito-live-infra/out/ha"
mkdir -p "$OUT"
IMAGE="postgres@sha256:d74eeac9a635390a49bc21bd49fccd973de707e2a53a76ac49b552b8712ec46f"
docker network create avito-ha >/dev/null
docker volume create avito-primary >/dev/null
docker volume create avito-standby >/dev/null
cleanup(){
  docker rm -f pg-primary pg-standby >/dev/null 2>&1 || true
  docker volume rm avito-primary avito-standby >/dev/null 2>&1 || true
  docker network rm avito-ha >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker run -d --name pg-primary --network avito-ha --network-alias primary \
  -e POSTGRES_PASSWORD=postgres -v avito-primary:/var/lib/postgresql/data \
  "$IMAGE" postgres -c wal_level=replica -c max_wal_senders=10 -c max_replication_slots=10 -c hot_standby=on >/dev/null
for i in $(seq 1 60); do docker exec pg-primary pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
docker exec pg-primary psql -U postgres -v ON_ERROR_STOP=1 -q -c "create role replicator with replication login password 'replpass';"
docker exec pg-primary bash -lc "echo 'host replication replicator 0.0.0.0/0 scram-sha-256' >> /var/lib/postgresql/data/pg_hba.conf"
docker exec pg-primary psql -U postgres -Atqc "select pg_reload_conf();" >/dev/null
docker run --rm --network avito-ha -e PGPASSWORD=replpass -v avito-standby:/var/lib/postgresql/data \
  --entrypoint bash "$IMAGE" -lc "rm -rf /var/lib/postgresql/data/*; chown postgres:postgres /var/lib/postgresql/data; gosu postgres pg_basebackup -h primary -U replicator -D /var/lib/postgresql/data -X stream -R"
docker run -d --name pg-standby --network avito-ha --network-alias standby \
  -v avito-standby:/var/lib/postgresql/data "$IMAGE" postgres >/dev/null
for i in $(seq 1 60); do docker exec pg-standby pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
RECOVERY="$(docker exec pg-standby psql -U postgres -Atqc "select pg_is_in_recovery();")"
STREAMING="$(docker exec pg-primary psql -U postgres -Atqc "select count(*) from pg_stat_replication where state='streaming';")"
docker exec pg-primary psql -U postgres -v ON_ERROR_STOP=1 -q -c "create table ha_probe(id int primary key,note text); insert into ha_probe values(1,'before-failover');"
for i in $(seq 1 100); do
  C="$(docker exec pg-standby psql -U postgres -Atqc "select count(*) from ha_probe where id=1;" 2>/dev/null || echo 0)"
  [ "$C" = "1" ] && break
  sleep 0.1
done
PRE_ROW="$(docker exec pg-standby psql -U postgres -Atqc "select count(*) from ha_probe where id=1;")"
T0="$(date +%s%3N)"
docker stop -t 1 pg-primary >/dev/null
docker exec -u postgres pg-standby pg_ctl -D /var/lib/postgresql/data promote >/dev/null
for i in $(seq 1 100); do
  R="$(docker exec pg-standby psql -U postgres -Atqc "select pg_is_in_recovery();" 2>/dev/null || echo t)"
  [ "$R" = "f" ] && break
  sleep 0.1
done
docker exec pg-standby psql -U postgres -v ON_ERROR_STOP=1 -q -c "insert into ha_probe values(2,'after-failover');"
T1="$(date +%s%3N)"
RTO=$((T1-T0))
ROWS="$(docker exec pg-standby psql -U postgres -Atqc "select count(*) from ha_probe;")"
POST_RECOVERY="$(docker exec pg-standby psql -U postgres -Atqc "select pg_is_in_recovery();")"
VER="$(docker exec pg-standby psql -U postgres -Atqc "select version();")"
python3 - "$OUT/report.json" "$VER" "$RECOVERY" "$STREAMING" "$PRE_ROW" "$POST_RECOVERY" "$ROWS" "$RTO" <<'PY'
import json,sys
out,ver,recovery,streaming,pre,post,rows,rto=sys.argv[1:]
r={
 "gate":"M57B_POSTGRES_PROCESS_HA_LIVE",
 "postgres_version":ver,
 "standby_was_in_recovery":recovery=="t",
 "streaming_replica_count":int(streaming),
 "pre_failover_committed_row_replicated":int(pre)==1,
 "promoted_node_writable":post=="f",
 "rows_after_failover":int(rows),
 "failover_rto_ms":int(rto),
 "committed_probe_rpo_rows_lost":0 if int(pre)==1 and int(rows)>=2 else 1,
 "independent_host_failure_domain":False
}
r["status"]="PASS" if all([
 r["standby_was_in_recovery"],r["streaming_replica_count"]>=1,
 r["pre_failover_committed_row_replicated"],r["promoted_node_writable"],
 r["rows_after_failover"]==2,r["committed_probe_rpo_rows_lost"]==0
]) else "FAIL"
json.dump(r,open(out,"w"),indent=2)
print(json.dumps(r,indent=2))
raise SystemExit(0 if r["status"]=="PASS" else 2)
PY
