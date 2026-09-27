SET search_path = avito_lot_os, pg_catalog;
ALTER FUNCTION avitolog_forbid_mutation() SET search_path = avito_lot_os, pg_catalog;
ALTER FUNCTION avitolog_claim_confirm_guard() SET search_path = avito_lot_os, pg_catalog;
REVOKE EXECUTE ON FUNCTION avitolog_forbid_mutation() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION avitolog_claim_confirm_guard() FROM PUBLIC, anon, authenticated;
DO $$
DECLARE r record; cols text; idx_name text;
BEGIN
  FOR r IN
    WITH fks AS (
      SELECT c.conname,c.conrelid,c.conkey,t.relname,array_length(c.conkey,1) ncols
      FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace n ON n.oid=t.relnamespace
      WHERE c.contype='f' AND n.nspname='avito_lot_os'
    ) SELECT f.* FROM fks f WHERE NOT EXISTS (
      SELECT 1 FROM pg_index i WHERE i.indrelid=f.conrelid AND i.indisvalid AND i.indpred IS NULL
      AND (SELECT array_agg(u.attnum ORDER BY u.ord) FROM unnest(i.indkey::smallint[]) WITH ORDINALITY u(attnum,ord) WHERE u.ord<=f.ncols)=f.conkey
    )
  LOOP
    SELECT string_agg(format('%I',a.attname),', ' ORDER BY u.ord) INTO cols
    FROM unnest(r.conkey) WITH ORDINALITY u(attnum,ord) JOIN pg_attribute a ON a.attrelid=r.conrelid AND a.attnum=u.attnum;
    idx_name:=left('ix_fk_'||r.conname,63);
    EXECUTE format('create index if not exists %I on avito_lot_os.%I (%s)',idx_name,r.relname,cols);
  END LOOP;
END $$;
DO $$
DECLARE t text; tables text[]:=ARRAY['tenants','projects','lots','sources','source_versions','source_policies','connector_definitions','collection_runs','artifacts','snapshots','snapshot_artifacts','observations','claims','evidence_links','lot_source_links','audit_events','server_state_revisions','schema_migrations'];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('alter table avito_lot_os.%I enable row level security',t);
    EXECUTE format('create policy %I on avito_lot_os.%I for all to anon, authenticated using (false) with check (false)',left('deny_public_'||t,63),t);
  END LOOP;
END $$;
CREATE OR REPLACE FUNCTION avitolog_append_state_revision(p_tenant_id varchar,p_project_id varchar,p_expected_base_revision bigint,p_sha256 varchar,p_state jsonb,p_note text default null) RETURNS bigint
LANGUAGE plpgsql SECURITY INVOKER SET search_path=avito_lot_os,pg_catalog AS $$
DECLARE v_current bigint; v_new bigint;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant_id||':'||p_project_id,0));
  SELECT coalesce(max(revision),0) INTO v_current FROM server_state_revisions WHERE tenant_id=p_tenant_id AND project_id=p_project_id;
  IF v_current<>p_expected_base_revision THEN RAISE EXCEPTION 'stale base revision: expected %, current %',p_expected_base_revision,v_current USING ERRCODE='40001'; END IF;
  INSERT INTO server_state_revisions(tenant_id,project_id,sha256,state,note,base_revision) VALUES(p_tenant_id,p_project_id,p_sha256,p_state,p_note,p_expected_base_revision) RETURNING revision INTO v_new;
  RETURN v_new;
END $$;
REVOKE EXECUTE ON FUNCTION avitolog_append_state_revision(varchar,varchar,bigint,varchar,jsonb,text) FROM PUBLIC, anon, authenticated;
