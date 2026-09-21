import copy
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
from dataclasses import replace
from unittest.mock import patch
import socket
import zipfile
import windows_handoff_fixtures as f
import receive_fixtures as rf
import receive_ab_simulator as ab
w,c=f.w,f.c


class WindowsMappingTests(unittest.TestCase):
    def setUp(self): self.files,self.h,self.binding=f.fixture()
    def mapped(self,target=False):
        f.seal(self.files,self.h,target)
        return w.map_draft(self.files,c.sha(self.files['handoff.json']),self.binding)
    def edit(self,name,fn):
        name='source/'+name;v=c.strict_json(self.files[name]);fn(v);self.files[name]=c.json_bytes(v)
    def blocked(self,code=None,target=False):
        with self.assertRaises(c.ContractError) as ex:self.mapped(target)
        if code:self.assertEqual(ex.exception.code,code)
    def test_mapping_retains_false_authority(self):
        r=self.mapped();self.assertTrue(r.report['mapping_connected']);self.assertEqual(r.report['target_counts'],dict(members=4,references=1,context_only=0))
        self.assertFalse(any(r.report['authority'].values()));self.assertFalse(r.report['fresh_ab_passes_verified'])
    def test_input_immutable_and_private_copy(self):
        f.seal(self.files,self.h);before=copy.deepcopy(self.files)
        r=w.map_draft(self.files,c.sha(self.files['handoff.json']),self.binding);self.assertEqual(before,self.files)
        x=r.comparison_expected();x.target['members']['documents'][0]['content']='changed'
        self.assertNotEqual(x,r.comparison_expected())
    def test_apply_always_blocked(self):
        with self.assertRaisesRegex(c.ContractError,'REAL_CONTRACT_UNRESOLVED'):self.mapped().require_apply_input()
    def test_external_pin(self):
        f.seal(self.files,self.h)
        with self.assertRaisesRegex(c.ContractError,'HANDOFF_PIN'):w.map_draft(self.files,'0'*64,self.binding)
    def test_external_binding(self):
        self.binding=copy.deepcopy(self.binding);self.binding['account_id']=rf.uid(99);self.blocked('EXTERNAL_BINDING')
    def test_old_format_not_silently_relabelled(self):
        self.h['format']='windows-isolated-receive-handoff-v1';self.blocked('FORMAT')
    def test_finalized_rejected(self):self.h['schema_finalized']=True;self.blocked('FORMAT')
    def test_authority_rejected(self):self.h['authority']['baseline_ready']=True;self.blocked('AUTHORITY')
    def test_artifact_raw_tamper(self):
        f.seal(self.files,self.h);self.files['source/Q14.body']+=b' '
        with self.assertRaisesRegex(c.ContractError,'ARTIFACT_HASH'):w.map_draft(self.files,c.sha(self.files['handoff.json']),self.binding)
    def test_missing_raw(self):
        f.seal(self.files,self.h);del self.files['source/Q14.body']
        with self.assertRaises(c.ContractError):w.map_draft(self.files,c.sha(self.files['handoff.json']),self.binding)
    def test_duplicate_json_key(self):
        self.files['source/Q1.body']=b'{"id":1,"id":2}';self.blocked('DUPLICATE_KEY')
    def test_source_seal(self):
        f.seal(self.files,self.h);d=c.strict_json(self.files['completed.json']);d['source_files']['Q14.body']='0'*64;self.files['completed.json']=c.json_bytes(d)
        with self.assertRaisesRegex(c.ContractError,'SOURCE_SEAL'):w.map_draft(self.files,c.sha(self.files['handoff.json']),self.binding)
    def test_plan_canonical_hash(self):
        self.edit('plan.json',lambda v:v.update(root_path='changed'));self.blocked('PLAN_HASH')
    def test_plan_reference_hash(self):
        self.files['source/reference-metadata.json']=b'[{}]\n';self.blocked('PLAN_REFERENCE_HASH')
    def test_no_ref_row_substitution(self):
        self.h['target']['members'][0]['source_refs'][0]['json_pointer']='/1';self.blocked('TARGET_SOURCE_ID',True)
    def test_original_array_pointer_leading_zero(self):
        self.h['target']['members'][0]['source_refs'][0]['json_pointer']='/00';self.blocked('POINTER_INDEX',True)
    def test_no_version_conversion(self):
        self.h['target']['members'][0]['revision']='1';self.blocked('TARGET_VALUE',True)
    def test_order_sequence_preserved(self):
        next(e for e in self.h['target']['members'] if e['entity_kind']=='tree_order')['children'].reverse();self.blocked('TARGET_ORDER',True)
    def test_body_byte_metadata(self):
        self.h['target']['members'][0]['body']['utf8_bytes']+=1;self.blocked('TARGET_BODY',True)
    def test_date_missing(self):
        self.edit('Q14.body',lambda v:v[0].pop('updated_at'));self.blocked('MISSING_FIELD')
    def test_delete_null_contradiction(self):
        self.edit('Q14.body',lambda v:v[0].update(deleted_at=rf.DATE));self.blocked('DELETION_DATE')
    def test_target_role_coverage(self):
        self.h['target']['references']=[];self.blocked('TARGET_COVERAGE',True)
    def test_member_actions_stay_empty(self):
        self.h['target']['members'][0]['allowed_actions']=['apply'];self.blocked('TARGET_AUTHORITY',True)
    def test_project_trashed_not_invented_boolean(self):
        r=self.mapped();self.assertEqual(r.comparison_expected().project_state_field,'trashed_at')
        self.assertNotIn('is_deleted',c.strict_json(self.files['source/Q12.body'])[0])
    def test_project_trash_is_blocked(self):
        self.edit('Q12.body',lambda v:v[0].update(trashed_at=rf.DATE));self.blocked('PROJECT_TRASHED')
    def test_project_trash_field_missing_is_blocked(self):
        self.edit('Q12.body',lambda v:v[0].pop('trashed_at'));self.blocked('MISSING_FIELD')
    def test_project_conflicting_state_is_blocked(self):
        self.edit('Q12.body',lambda v:v[0].update(is_deleted=True));self.blocked('PROJECT_STATE_CONFLICT')
    def test_handshake_wrong_contract(self):
        self.edit('Q2.body',lambda v:v.update(server_contract_sha256='0'*64));self.blocked('CONTRACT')
    def test_handshake_singleton_adapter(self):
        hs=c.strict_json(self.files['source/Q2.body']);self.files['source/Q2.body']=c.json_bytes([hs]);data=self.files['source/Q2.body']
        self.edit('004-response.json',lambda v:v.update(bytes=len(data),sha256=c.sha(data)))
        self.assertTrue(self.mapped().report['handshake_retained_contract_checked'])
    def test_missing_evidence_typed_namespace(self):
        r=self.mapped();self.assertEqual(r.report['missing_evidence_count'],52)
        self.assertFalse(r.report['http_total_verified']);self.assertFalse(r.report['request_times_verified'])
    def test_raw_count_recomputed(self):
        self.h['evidence']['Q14.row_count']['value']=99;self.blocked('RAW_COUNT')
    def test_invented_timestamp_rejected(self):
        self.h['evidence']['Q1.started_at'].update(state='local_measured',value=1000);self.blocked('MISSING_EVIDENCE_STATE')
    def test_missing_placeholder_not_filled(self):
        self.h['missing_evidence'].pop();self.blocked()
    def test_creation_operation_receipt_link(self):
        self.edit('Q9.body',lambda v:v['results'][0].update(operation_id=rf.uid(999)));self.blocked('INTENT_LINK')
    def test_creation_batch_payload_hash(self):
        self.edit('creation-requests.json',lambda v:v[0]['ordered_intents'][0]['payload'].update(name='changed'));self.blocked('BATCH_HASH')
    def test_creation_failed_not_success(self):
        self.edit('Q9.body',lambda v:v.update(applied=False));self.blocked('CREATION_STATUS')
    def test_response_bool_revision(self):
        self.edit('Q9.body',lambda v:v['results'][0].update(result_revision=True));self.blocked('INTEGER')
    def test_candidate_readback_content(self):
        self.edit('baseline-candidate.json',lambda v:v['candidate']['documents'][0].update(content='different'));self.blocked('CANDIDATE_ROWS')
    def test_preexisting_row_preserved(self):
        self.edit('Q7.body',lambda v:v[0].update(new_unknown_field=123));self.blocked('PROTECTED_ROW')
    def test_request_limit_allowlist(self):
        self.h['observations'][13]['query']['limit']='20000';self.blocked('REQUEST_CONTRACT')
    def test_reservation_precharge(self):
        self.edit('015-reserved.json',lambda v:v.update(writes_reserved=0));self.blocked('RESERVATION')
    def test_terminal_cannot_resume(self):
        self.edit('038-terminal.json',lambda v:v.update(resumable=True));self.blocked('TERMINAL_AUTHORITY')
    def test_received_verification_claim_is_not_adopted(self):
        self.h['checks'][0]['independent'].update(state='pass',value=True)
        self.h['server_provenance_verified']=True
        self.assertFalse(self.mapped().report['server_provenance_verified'])
    def test_future_pass_uses_mapped_expected_and_real_project_shape(self):
        r=self.mapped();v=[c.strict_json(self.files['source/Q%d.body'%n]) for n in (1,2,12,13,14,15,16)]
        result=c.validate_pass(rf.responses(v),r.comparison_expected())
        self.assertEqual(len(result['normal_body_hashes']),2)
    def test_missing_headers_not_fabricated_for_future_pass(self):
        r=self.mapped();v=[c.strict_json(self.files['source/Q%d.body'%n]) for n in (1,2,12,13,14,15,16)]
        responses=rf.responses(v);responses[2]=ab.MockResponse(c.json_bytes(v[2]),content_range=None)
        with self.assertRaisesRegex(c.ContractError,'COUNT'):c.validate_pass(responses,r.comparison_expected())
    def test_future_ab_change_still_detected(self):
        r=self.mapped();v=[c.strict_json(self.files['source/Q%d.body'%n]) for n in (1,2,12,13,14,15,16)]
        responses=rf.responses(v)+rf.responses(v);v2=copy.deepcopy(v);v2[4][0]['content']='later'
        responses=rf.responses(v)+rf.responses(v2)
        # Direct paid-pass gate uses the same Expected; no old source is labelled current.
        with self.assertRaisesRegex(c.ContractError,'TARGET_CHANGED'):c.validate_pass(responses[7:],r.comparison_expected())
    def test_old_u1_reviewer_stays_strict(self):
        f.seal(self.files,self.h)
        with self.assertRaises(c.ContractError):c.review_handoff(self.files)
    def test_zip_loader_and_no_extraction(self):
        f.seal(self.files,self.h)
        with tempfile.TemporaryDirectory(prefix='synthetic-handoff-') as tmp:
            p=Path(tmp)/'test.zip'
            with zipfile.ZipFile(p,'w') as z:
                for n,x in self.files.items():z.writestr('bundle/'+n,x)
                z.writestr('local-sources/do-not-run.py',b'raise RuntimeError("must not execute")')
            self.assertEqual(w.read_zip(p),self.files);self.assertEqual(list(Path(tmp).iterdir()),[p])
    def test_zip_traversal_blocked(self):
        with tempfile.TemporaryDirectory(prefix='synthetic-handoff-') as tmp:
            p=Path(tmp)/'test.zip'
            with zipfile.ZipFile(p,'w') as z:z.writestr('../handoff.json',b'{}')
            with self.assertRaisesRegex(c.ContractError,'PATH'):w.read_zip(p)
    def test_zip_symlink_blocked(self):
        with tempfile.TemporaryDirectory(prefix='synthetic-handoff-') as tmp:
            p=Path(tmp)/'test.zip'
            with zipfile.ZipFile(p,'w') as z:
                info=zipfile.ZipInfo('bundle/handoff.json');info.external_attr=(stat.S_IFLNK|0o777)<<16;z.writestr(info,b'elsewhere')
            with self.assertRaisesRegex(c.ContractError,'ZIP_LINK'):w.read_zip(p)
    def test_reference_cannot_be_hidden_as_context(self):
        self.h['target']['context_only'].append(self.h['target']['references'].pop())
        self.blocked('REFERENCE_ROLE_SCOPE',True)
    def test_body_metadata_bool_not_integer(self):
        self.h['target']['members'][0]['body']['utf8_bytes']=True;self.blocked('INTEGER',True)
    def test_zero_reservation_bool_not_integer(self):
        self.edit('001-reserved.json',lambda v:v.update(http_reserved=True));self.blocked('INTEGER')
    def test_client_capability_contract(self):
        self.edit('creation-requests.json',lambda v:v[0]['batch'].update(client_capabilities=[]));self.blocked('CREATION_CAPABILITIES')
    def test_server_capabilities_cannot_replace_client_capabilities(self):
        self.edit('creation-requests.json',lambda v:v[0]['batch'].update(client_capabilities=sorted(c.CAPABILITIES)))
        self.blocked('CREATION_CAPABILITIES')
    def test_input_project_mode_is_bound_to_ab_journal(self):
        x=self.mapped().comparison_expected();one=ab.ABRunner(x,rf.timing(),rf.RUN)
        two=ab.ABRunner(replace(x,project_state_field='is_deleted'),rf.timing(),rf.RUN)
        self.assertNotEqual(one.binding,two.binding)
    def test_synthetic_mapping_through_full_ab_policy(self):
        r=self.mapped();v=[c.strict_json(self.files['source/Q%d.body'%n]) for n in (1,2,12,13,14,15,16)]
        exchange=ab.SyntheticExchange(rf.responses(v)+rf.responses(v));journal=ab.SyntheticJournal()
        with patch.object(socket,'socket',side_effect=AssertionError('network forbidden')):
            result=ab.ABRunner(r.comparison_expected(),rf.timing(),rf.RUN).run(exchange,journal,ab.FakeClock(1000))
        self.assertTrue(result['synthetic_policy_passed']);self.assertEqual(result['http_reserved'],14)
        self.assertFalse(result['baseline_applied']);self.assertFalse(result['baseline_ready'])
    def test_future_real_shape_does_not_fall_back_to_synthetic(self):
        r=self.mapped();v=[c.strict_json(self.files['source/Q%d.body'%n]) for n in (1,2,12,13,14,15,16)]
        v[2][0].pop('trashed_at');v[2][0]['is_deleted']=False
        with self.assertRaisesRegex(c.ContractError,'MISSING_FIELD'):c.validate_pass(rf.responses(v),r.comparison_expected())
    def test_report_has_no_manuscript_body(self):
        r=self.mapped();encoded=json.dumps(r.report,ensure_ascii=False)
        for doc in r.comparison_expected().target['members']['documents']:
            if doc['content']:self.assertNotIn(doc['content'],encoded)
        self.assertNotIn('"content":',encoded)
    def test_canonical_lf_distinction(self):
        v={'name':'e\u0301🙂\n','value':1};self.assertEqual(w.canonical_digest(v),c.sha(c.json_bytes(v)[:-1]));self.assertNotEqual(w.canonical_digest(v),c.sha(c.json_bytes(v)))
    def test_canonical_float_rejected(self):
        with self.assertRaisesRegex(c.ContractError,'CANONICAL_TYPE'):w.canonical_digest({'value':1.0})


if __name__=='__main__':unittest.main()
