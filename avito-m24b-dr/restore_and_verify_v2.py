#!/usr/bin/env python3
import json,subprocess,hashlib,os,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parent
DATA=json.load(open(ROOT/'source_data.json'))
MAN=json.load(open(ROOT/'source_manifest.json'))
ORDER=['tenants','projects','lots','sources','source_versions','source_policies','connector_definitions','collection_runs','artifacts','snapshots','snapshot_artifacts','observations','claims','evidence_links','lot_source_links','audit_events','server_state_revisions','schema_migrations']
KEYS={'tenants':'tenant_id','projects':'project_id','lots':'lot_id','sources':'source_id','source_versions':'source_version_id','source_policies':'source_policy_id','connector_definitions':'connector_id','collection_runs':'run_id','artifacts':'artifact_id','snapshots':'snapshot_id','snapshot_artifacts':'snapshot_id,artifact_id','observations':'observation_id','claims':'claim_id','evidence_links':'evidence_link_id','lot_source_links':'lot_id,source_id','audit_events':'audit_id','server_state_revisions':'revision','schema_migrations':'migration_id'}
def psql(sql, capture=False):
    e=os.environ.copy(); e['PGOPTIONS']='-c search_path=avito_lot_os,pg_catalog'
    return subprocess.run(['psql','-v','ON_ERROR_STOP=1','-Atq','-c',sql],env=e,text=True,capture_output=capture,check=True).stdout if capture else subprocess.run(['psql','-v','ON_ERROR_STOP=1','-q','-c',sql],env=e,check=True)
def canon(x): return json.dumps(x,ensure_ascii=False,sort_keys=True,separators=(',',':'))
def digest(x): return hashlib.sha256(canon(x).encode()).hexdigest()
# Roles/schema are disposable CI-only.
subprocess.run(['psql','-v','ON_ERROR_STOP=1','-q','-c',"DO $$BEGIN IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF; IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF; END$$; CREATE SCHEMA avito_lot_os;"],check=True)
env=os.environ.copy();env['PGOPTIONS']='-c search_path=avito_lot_os,pg_catalog'
for f in [ROOT.parent/'avito-m52b-canonical/001_core.up.sql',ROOT.parent/'avito-m52b-canonical/002_immutability_guards.up.sql',ROOT/'003_live_hardening.sql']:
    subprocess.run(['psql','-v','ON_ERROR_STOP=1','-q','-f',str(f)],env=env,check=True)
# Restore all rows in one deferred transaction.
parts=['BEGIN;','SET CONSTRAINTS ALL DEFERRED;']
for t in ORDER:
    rows=DATA[t]
    if rows:
        payload=json.dumps(rows,ensure_ascii=False,separators=(',',':'))
        parts.append(f"INSERT INTO {t} SELECT * FROM jsonb_populate_recordset(NULL::{t}, $json${payload}$json$::jsonb);")
parts += ["SET CONSTRAINTS ALL IMMEDIATE;","SELECT setval(pg_get_serial_sequence('audit_events','audit_id'),coalesce(max(audit_id),1),max(audit_id) is not null) FROM audit_events;","SELECT setval(pg_get_serial_sequence('server_state_revisions','revision'),coalesce(max(revision),1),max(revision) is not null) FROM server_state_revisions;","COMMIT;"]
psql('\n'.join(parts))
# Compare row arrays with source_data using canonical JSON, not provider-specific textual spacing.
report={'tables':{},'guards':{},'pass':True}
for t in ORDER:
    order=KEYS[t]
    txt=psql(f"select coalesce(jsonb_agg(to_jsonb(x) order by {order}),'[]'::jsonb)::text from {t} x",True).strip()
    actual=json.loads(txt or '[]'); exp=DATA[t]
    ok=(canon(actual)==canon(exp)); report['tables'][t]={'rows':len(actual),'expected_rows':len(exp),'sha256':digest(actual),'expected_sha256_canonical':digest(exp),'match':ok};report['pass'] &= ok
# metadata
meta=json.loads(psql("select json_build_object('tables',(select count(*) from information_schema.tables where table_schema='avito_lot_os'),'policies',(select count(*) from pg_policies where schemaname='avito_lot_os'),'triggers',(select count(distinct trigger_name) from information_schema.triggers where trigger_schema='avito_lot_os'),'functions',(select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='avito_lot_os' and p.proname like 'avitolog_%'))::text",True).strip())
report['metadata']=meta; report['pass'] &= meta=={'tables':18,'policies':18,'triggers':3,'functions':3}
# guards: each negative mutation must fail.
def must_fail(name,sql):
    e=os.environ.copy();e['PGOPTIONS']='-c search_path=avito_lot_os,pg_catalog';r=subprocess.run(['psql','-v','ON_ERROR_STOP=1','-q','-c',sql],env=e,text=True,capture_output=True);ok=r.returncode!=0;report['guards'][name]=ok;report['pass'] &= ok
must_fail('artifact_immutable',"update artifacts set status='X' where artifact_id='art1'")
must_fail('audit_append_only',"delete from audit_events where audit_id=1")
must_fail('claim_requires_evidence',"begin; insert into claims(claim_id,tenant_id,project_id,source_id,created_by,updated_by,status,classification,observation_id,subject,predicate,object_value,confidence_milli,review_status,extractor_version) values('cl_neg','t1','p1','src1','qa','qa','ACTIVE','INTERNAL','obs1','lot1','x','1'::jsonb,500,'CONFIRMED','qa'); commit;")
must_fail('stale_revision',"select avitolog_append_state_revision('t1','p1',1,repeat('a',64),'{}'::jsonb,'stale')")
priv=psql("select (not has_schema_privilege('anon','avito_lot_os','USAGE')) and (not has_schema_privilege('authenticated','avito_lot_os','USAGE'))",True).strip()=='t';report['guards']['public_schema_denied']=priv;report['pass'] &= priv
(ROOT/'out').mkdir(exist_ok=True);json.dump(report,open(ROOT/'out/restore_report.json','w'),ensure_ascii=False,indent=2)
print(json.dumps(report,ensure_ascii=False,indent=2));sys.exit(0 if report['pass'] else 1)
