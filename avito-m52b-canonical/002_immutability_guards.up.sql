BEGIN;
CREATE OR REPLACE FUNCTION avitolog_forbid_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'immutable relation % cannot be %', TG_TABLE_NAME, TG_OP USING ERRCODE='55000';
END $$;
CREATE TRIGGER trg_artifacts_immutable_update BEFORE UPDATE OR DELETE ON artifacts FOR EACH ROW EXECUTE FUNCTION avitolog_forbid_mutation();
CREATE TRIGGER trg_audit_events_append_only BEFORE UPDATE OR DELETE ON audit_events FOR EACH ROW EXECUTE FUNCTION avitolog_forbid_mutation();
CREATE OR REPLACE FUNCTION avitolog_claim_confirm_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.review_status='CONFIRMED' AND NOT EXISTS (SELECT 1 FROM evidence_links e WHERE e.claim_id=NEW.claim_id) THEN
    RAISE EXCEPTION 'claim % cannot be CONFIRMED without EvidenceLink', NEW.claim_id USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $$;
CREATE CONSTRAINT TRIGGER trg_claim_confirm_evidence AFTER INSERT OR UPDATE OF review_status ON claims DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION avitolog_claim_confirm_guard();
COMMIT;
