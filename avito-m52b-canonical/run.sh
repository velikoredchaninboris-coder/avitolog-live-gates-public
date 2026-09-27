#!/usr/bin/env bash
set -euo pipefail

OUT="avito-m52b-canonical/out"
mkdir -p "$OUT"
: > "$OUT/timings.env"
ms_now(){ date +%s%3N; }
record(){ printf '%s=%s\n' "$1" "$2" >> "$OUT/timings.env"; }

psql -v ON_ERROR_STOP=1 -Atqc "select version();" > "$OUT/postgres_version.txt"
{
  echo '=== CPU ==='; lscpu
  echo '=== MEMORY ==='; free -h
  echo '=== DISK ==='; df -h /
} > "$OUT/runner_resources_before.txt"

FREE_BYTES=$(df -B1 --output=avail / | tail -1 | tr -d ' ')
record runner_free_bytes_before "$FREE_BYTES"
if [ "$FREE_BYTES" -lt $((8*1024*1024*1024)) ]; then
  echo "SAFETY_STOP: <8GiB free before benchmark" >&2
  exit 40
fi

# Keep checkpoint churn bounded on disposable CI Postgres.
psql -v ON_ERROR_STOP=1 -q <<'SQL'
alter system set max_wal_size='4GB';
alter system set checkpoint_timeout='15min';
select pg_reload_conf();
SQL
psql -Atqc "select 'max_wal_size='||current_setting('max_wal_size') union all select 'checkpoint_timeout='||current_setting('checkpoint_timeout');" > "$OUT/postgres_tuning.txt"

T0=$(ms_now)
psql -v ON_ERROR_STOP=1 -f avito-m52b-canonical/001_core.up.sql > "$OUT/migration_001.log"
psql -v ON_ERROR_STOP=1 -f avito-m52b-canonical/002_immutability_guards.up.sql > "$OUT/migration_002.log"
T1=$(ms_now); record canonical_migrations_ms $((T1-T0))

# Seed the minimal valid canonical dependency chain. No fixture reaches production.
psql -v ON_ERROR_STOP=1 -q <<'SQL'
insert into tenants(tenant_id,name,status) values('t_perf','M52B canonical performance','QA');
insert into projects(project_id,tenant_id,name,status) values('p_perf','t_perf','M52B canonical performance','QA');
insert into sources(source_id,tenant_id,project_id,created_by,updated_by,status,source_type,official_name,canonical_url,owner_name,legal_decision,passport)
values('src_perf','t_perf','p_perf','ci','ci','ACTIVE','CI','M52B canonical','ci://m52b-canonical','ci','APPROVED','{}');
insert into connector_definitions(connector_id,tenant_id,project_id,source_id,created_by,updated_by,status,connector_type,config_schema,code_version,owner,checkpoint)
values('con_perf','t_perf','p_perf','src_perf','ci','ci','ACTIVE','CI','{}','1','ci','{}');
insert into collection_runs(run_id,tenant_id,project_id,source_id,created_by,updated_by,status,connector_id,started_at,result)
values('seed_run','t_perf','p_perf','src_perf','ci','ci','SUCCESS','con_perf',now(),'{}');
SQL

# Canonical Artifact needed for observation/evidence negative guards; immutable by trigger.
psql -v ON_ERROR_STOP=1 -q <<'SQL'
insert into artifacts(artifact_id,tenant_id,project_id,source_id,created_by,updated_by,status,run_id,mime_type,size_bytes,content_sha256,storage_sha256,storage_uri,manifest)
values('art_perf','t_perf','p_perf','src_perf','ci','ci','ACTIVE','seed_run','application/json',2,repeat('a',64),repeat('b',64),'ci://artifact','{}');
SQL

# 1M canonical snapshots simultaneously resident.
T0=$(ms_now)
psql -v ON_ERROR_STOP=1 -q <<'SQL'
insert into snapshots(snapshot_id,tenant_id,project_id,source_id,created_by,updated_by,status,run_id,captured_at,manifest,snapshot_sha256)
select
  g::text,
  't_perf','p_perf','src_perf','ci','ci','ACTIVE','seed_run',
  timestamptz '2026-01-01 00:00:00+00' + make_interval(secs => g % 31536000),
  jsonb_build_object('source','m52b-canonical','ordinal',g),
  md5(g::text)||md5('snap'||g::text)
from generate_series(1,1000000) g;
analyze snapshots;
SQL
T1=$(ms_now); record load_1m_snapshots_ms $((T1-T0))

DB_AFTER_SNAPS=$(psql -Atqc "select pg_database_size(current_database());")
record db_after_snapshots_bytes "$DB_AFTER_SNAPS"
FREE_AFTER_SNAPS=$(df -B1 --output=avail / | tail -1 | tr -d ' ')
record runner_free_bytes_after_snapshots "$FREE_AFTER_SNAPS"
if [ "$FREE_AFTER_SNAPS" -lt $((7*1024*1024*1024)) ]; then
  echo "SAFETY_STOP: <7GiB free after snapshots" >&2
  exit 41
fi

# 10M canonical claims simultaneously resident. observation_id is optional by canonical contract.
# review_status excludes CONFIRMED so evidence guard must not block ingestion.
T0=$(ms_now)
psql -v ON_ERROR_STOP=1 -q <<'SQL'
insert into claims(claim_id,tenant_id,project_id,source_id,created_by,updated_by,status,subject,predicate,object_value,confidence_milli,review_status,extractor_version)
select
  g::text,
  't_perf','p_perf','src_perf','ci','ci','ACTIVE',
  'LOT-'||(g%100000),
  case when g%4=0 then 'model' when g%4=1 then 'price' when g%4=2 then 'condition' else 'seller' end,
  jsonb_build_object('v',g%100000,'s',g%1000),
  (700 + (g%301))::int,
  case when g%10=0 then 'PENDING_REVIEW' else 'SUPPORTED' end,
  'm52b-canonical-v1'
from generate_series(1,10000000) g;
analyze claims;
SQL
T1=$(ms_now); record load_10m_claims_ms $((T1-T0))

DB_AFTER_CLAIMS=$(psql -Atqc "select pg_database_size(current_database());")
record db_after_claims_bytes "$DB_AFTER_CLAIMS"
FREE_AFTER_CLAIMS=$(df -B1 --output=avail / | tail -1 | tr -d ' ')
record runner_free_bytes_after_claims "$FREE_AFTER_CLAIMS"
if [ "$FREE_AFTER_CLAIMS" -lt $((3*1024*1024*1024)) ]; then
  echo "SAFETY_STOP: <3GiB free after claims" >&2
  exit 42
fi

# Canonical search + passport indexes already exist in migration; add query-shape index only if absent.
T0=$(ms_now)
psql -v ON_ERROR_STOP=1 -q <<'SQL'
create index if not exists ix_claims_subject_review on claims(subject,review_status);
analyze claims;
SQL
T1=$(ms_now); record add_query_index_ms $((T1-T0))

# 100 concurrent logical collection runs in 20 independent DB sessions × 5 runs.
for batch in $(seq 0 19); do
  (
    first=$((batch*5+1)); last=$((first+4));
    psql -v ON_ERROR_STOP=1 -q <<SQL
insert into collection_runs(run_id,tenant_id,project_id,source_id,created_by,updated_by,status,connector_id,started_at,result)
select 'c_'||g,'t_perf','p_perf','src_perf','ci','ci','ACTIVE','con_perf',clock_timestamp(),'{}'::jsonb
from generate_series($first,$last) g;
select pg_sleep(2);
update collection_runs set status='SUCCESS',finished_at=clock_timestamp()
where run_id in (select 'c_'||g from generate_series($first,$last) g);
SQL
  ) &
done
sleep 0.8
ACTIVE=$(psql -Atqc "select count(*) from collection_runs where status='ACTIVE' and run_id like 'c_%';")
record concurrent_active_peak "$ACTIVE"
wait
SUCCESS_RUNS=$(psql -Atqc "select count(*) from collection_runs where status='SUCCESS' and run_id like 'c_%';")
record concurrent_success_runs "$SUCCESS_RUNS"

# Backlog is an auxiliary load structure because the canonical M20B contract has no backlog table.
psql -v ON_ERROR_STOP=1 -q <<'SQL'
create unlogged table bench_backlog(item_id bigint primary key,status char(1) not null,payload jsonb not null);
insert into bench_backlog select g,'Q',jsonb_build_object('lot',g%100000,'retry',g%5) from generate_series(1,500000) g;
create index ix_bench_backlog_status on bench_backlog(status);
analyze bench_backlog;
SQL
T0=$(ms_now)
psql -v ON_ERROR_STOP=1 -q -c "update bench_backlog set status='R' where status='Q';"
T1=$(ms_now); record backlog_recovery_500k_ms $((T1-T0))

# Entity graph is auxiliary because graph entities were introduced after M20B.
T0=$(ms_now)
psql -v ON_ERROR_STOP=1 -q <<'SQL'
create unlogged table bench_entity_edges(edge_id bigint primary key,from_entity int not null,to_entity int not null,relation smallint not null);
insert into bench_entity_edges select g,(g%200000)::int,((g*17+13)%200000)::int,(g%7)::smallint from generate_series(1,2000000) g;
create index ix_bench_edges_from on bench_entity_edges(from_entity);
create index ix_bench_edges_to on bench_entity_edges(to_entity);
analyze bench_entity_edges;
SQL
T1=$(ms_now); record graph_load_2m_edges_ms $((T1-T0))

create_latency_table='create unlogged table bench_latency_samples(kind text not null,sample_no int not null,latency_ms numeric not null);'
psql -q -c "$create_latency_table"

psql -v ON_ERROR_STOP=1 -q <<'SQL'
do $$ declare i int; t0 timestamptz; begin
  for i in 1..200 loop
    t0:=clock_timestamp();
    perform count(*) from claims where subject='LOT-'||((i*7919)%100000) and review_status='SUPPORTED';
    insert into bench_latency_samples values('search',i,extract(epoch from(clock_timestamp()-t0))*1000);
  end loop;
end $$;

do $$ declare i int; t0 timestamptz; begin
  for i in 1..200 loop
    t0:=clock_timestamp();
    perform snapshot_id,manifest from snapshots where source_id='src_perf' order by captured_at desc limit 20;
    insert into bench_latency_samples values('passport',i,extract(epoch from(clock_timestamp()-t0))*1000);
  end loop;
end $$;

do $$ declare i int; t0 timestamptz; begin
  for i in 1..50 loop
    t0:=clock_timestamp();
    perform count(*) from (
      with recursive walk(node,depth) as (
        select ((i*101)%200000)::int,0
        union all
        select e.to_entity,w.depth+1 from walk w join bench_entity_edges e on e.from_entity=w.node where w.depth<2
      ) select * from walk
    ) q;
    insert into bench_latency_samples values('graph',i,extract(epoch from(clock_timestamp()-t0))*1000);
  end loop;
end $$;
SQL

psql -At -F, -c "select kind,round(percentile_cont(0.50) within group(order by latency_ms)::numeric,3),round(percentile_cont(0.95) within group(order by latency_ms)::numeric,3),round(max(latency_ms),3) from bench_latency_samples group by kind order by kind;" > "$OUT/latencies.csv"
SEARCH_P95=$(psql -Atqc "select round(percentile_cont(0.95) within group(order by latency_ms)::numeric,3) from bench_latency_samples where kind='search';")
PASSPORT_P95=$(psql -Atqc "select round(percentile_cont(0.95) within group(order by latency_ms)::numeric,3) from bench_latency_samples where kind='passport';")
GRAPH_P95=$(psql -Atqc "select round(percentile_cont(0.95) within group(order by latency_ms)::numeric,3) from bench_latency_samples where kind='graph';")
record search_p95_ms "$SEARCH_P95"; record passport_p95_ms "$PASSPORT_P95"; record graph_p95_ms "$GRAPH_P95"

psql -c "explain (analyze,buffers,format text) select count(*) from claims where subject='LOT-42424' and review_status='SUPPORTED';" > "$OUT/explain_search.txt"
psql -c "explain (analyze,buffers,format text) with recursive walk(node,depth) as (select 42,0 union all select e.to_entity,w.depth+1 from walk w join bench_entity_edges e on e.from_entity=w.node where w.depth<2) select count(*) from walk;" > "$OUT/explain_graph.txt"

T0=$(ms_now)
psql -v ON_ERROR_STOP=1 -c "reindex table claims;" > "$OUT/reindex_claims.log"
T1=$(ms_now); record mass_reindex_claims_ms $((T1-T0))

T0=$(ms_now)
psql -v ON_ERROR_STOP=1 -c "\copy (select claim_id,subject,predicate,confidence_milli,review_status from claims where claim_id::bigint<=500000 order by claim_id::bigint) to '$OUT/large_case.csv' csv header"
T1=$(ms_now); record export_500k_case_ms $((T1-T0))
gzip -9 "$OUT/large_case.csv"

# Verify critical canonical guards still work after load.
psql -v ON_ERROR_STOP=1 -q <<'SQL'
create table bench_guard_results(test_name text primary key,pass boolean not null);
do $$ begin
  begin update artifacts set storage_uri='ci://tamper' where artifact_id='art_perf'; insert into bench_guard_results values('artifact_immutable',false);
  exception when sqlstate '55000' then insert into bench_guard_results values('artifact_immutable',true); end;
end $$;
insert into claims(claim_id,tenant_id,project_id,source_id,created_by,updated_by,status,subject,predicate,object_value,confidence_milli,review_status,extractor_version)
values('guard_claim','t_perf','p_perf','src_perf','ci','ci','ACTIVE','LOT-GUARD','model','{}',900,'EXTRACTED','guard');
do $$ begin
  begin update claims set review_status='CONFIRMED' where claim_id='guard_claim'; set constraints trg_claim_confirm_evidence immediate; insert into bench_guard_results values('claim_confirm_requires_evidence',false);
  exception when check_violation then insert into bench_guard_results values('claim_confirm_requires_evidence',true); end;
end $$;
SQL

SNAP_COUNT=$(psql -Atqc "select count(*) from snapshots;")
CLAIM_COUNT=$(psql -Atqc "select count(*) from claims where claim_id <> 'guard_claim';")
BACKLOG_RECOVERED=$(psql -Atqc "select count(*) from bench_backlog where status='R';")
EDGE_COUNT=$(psql -Atqc "select count(*) from bench_entity_edges;")
DB_BYTES=$(psql -Atqc "select pg_database_size(current_database());")
CLAIM_SUM=$(psql -Atqc "select sum(claim_id::bigint) from claims where claim_id ~ '^[0-9]+$';")
SNAP_SUM=$(psql -Atqc "select sum(snapshot_id::bigint) from snapshots;")
GUARDS_OK=$(psql -Atqc "select bool_and(pass) from bench_guard_results;")
record snapshots "$SNAP_COUNT"; record claims "$CLAIM_COUNT"; record backlog_recovered "$BACKLOG_RECOVERED"; record graph_edges "$EDGE_COUNT"; record database_bytes "$DB_BYTES"; record claims_id_sum "$CLAIM_SUM"; record snapshots_id_sum "$SNAP_SUM"; record canonical_guards_pass "$GUARDS_OK"

df -B1 / > "$OUT/runner_resources_after.txt"

python3 - <<'PY'
import json
from pathlib import Path
out=Path('avito-m52b-canonical/out')
vals={}
for line in (out/'timings.env').read_text().splitlines():
    k,v=line.split('=',1)
    if v in ('t','true'): vals[k]=True; continue
    if v in ('f','false'): vals[k]=False; continue
    try: vals[k]=float(v) if '.' in v else int(v)
    except ValueError: vals[k]=v
report={
 'gate':'M52B_CANONICAL_GITHUB_ACTIONS_POSTGRES17',
 'schema':'M20B_CANONICAL_18_TABLES_PLUS_AUX_WORKLOAD_TABLES',
 'targets':{'snapshots':1_000_000,'claims':10_000_000,'concurrent_collection_runs':100},
 'actual':vals,
 'slo':{
   'search_p95_limit_ms':3000,'passport_p95_limit_ms':3000,
   'search_pass':float(vals['search_p95_ms'])<=3000,
   'passport_pass':float(vals['passport_p95_ms'])<=3000,
 },
 'integrity':{
   'snapshots_exact':vals['snapshots']==1_000_000,
   'claims_exact':vals['claims']==10_000_000,
   'concurrency_exact':vals['concurrent_active_peak']==100 and vals['concurrent_success_runs']==100,
   'backlog_exact':vals['backlog_recovered']==500_000,
   'graph_edges_exact':vals['graph_edges']==2_000_000,
   'claims_sum_pass':vals['claims_id_sum']==50_000_005_000_000,
   'snapshots_sum_pass':vals['snapshots_id_sum']==500_000_500_000,
   'canonical_guards_pass':bool(vals['canonical_guards_pass']),
 },
 'status':'PASS'
}
checks=[report['slo']['search_pass'],report['slo']['passport_pass'],*report['integrity'].values()]
if not all(checks): report['status']='FAIL'
(out/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps(report,ensure_ascii=False,indent=2))
if report['status']!='PASS': raise SystemExit(2)
PY
