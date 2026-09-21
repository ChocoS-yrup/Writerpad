import copy
from dataclasses import replace
import unittest

from receive_fixtures import c, a, uid, ACCOUNT, PROJECT, ROOT, DOC, DOC2, DATE, dataset, expected, responses, envelope, repack


class ContractTests(unittest.TestCase):
    def reject(self, fn, code=None):
        with self.assertRaises(c.ContractError) as error: fn()
        if code: self.assertEqual(error.exception.code,code)

    def test_strict_json_ambiguity_and_encoding(self):
        for raw in (b'{"x":1,"x":2}',b'{"x":NaN}',b'1e9999',b'"\xff"',b'"\\ud800"',b'{',b'['*66+b'0'+b']'*66):
            with self.subTest(raw=raw): self.reject(lambda:c.strict_json(raw))

    def test_integer_bounds_no_coercion(self):
        for value in (True,False,1.0,'1',None,-1,c.MAX_INT+1):
            with self.subTest(value=value): self.reject(lambda:c.integer(value),'INTEGER')
        self.assertEqual(c.integer(c.MAX_INT),c.MAX_INT)

    def test_calendar_offset_fraction_and_lexical_preservation(self):
        for value in ('2024-02-29T23:59:59.1+14:00','2026-09-14T00:00:00-14:00',DATE): self.assertEqual(c.date(value),value)
        for value in ('2025-02-29T00:00:00Z','2026-01-01T24:00:00Z','2026-01-01T00:00:60Z',
            '2026-01-01T00:00:00.1234567Z','2026-01-01T00:00:00+14:01','2026-01-01T00:00:00+01:60',
            '2026-01-01','2026-01-01T00:00:00',None): self.reject(lambda:c.date(value))

    def test_body_byte_hash_empty_lf_and_no_normalization(self):
        self.assertEqual(c.body(''),dict(sha256=c.sha(b''),byte_count=0,ends_lf=False))
        self.assertNotEqual(c.body('e\u0301')['sha256'],c.body('é')['sha256'])
        self.assertTrue(c.body('🙂\n')['ends_lf'])
        self.assertEqual(c.body('🙂\n')['byte_count'],5)
        for value in ('a\r\nb','\0','\ud800',None): self.reject(lambda:c.body(value))

    def test_pointer_original_position_escapes_and_missing(self):
        obj={'a/b':{'~name':[{'id':DOC}]}}
        self.assertEqual(c.pointer(obj,'/a~1b/~0name/0/id'),DOC)
        self.assertIs(c.pointer(obj,''),obj)
        for ptr in ('/a~2b','/missing','/a~1b/~0name/01','/a~1b/~0name/-','/a~1b/~0name/2'):
            self.reject(lambda:c.pointer(obj,ptr))

    def test_paths_reject_traversal_drive_empty_and_controls(self):
        for p in ('/abs','../a','a/../b','a//b','C:/x','a\\b','a/./b','a\n',''):
            self.reject(lambda:c.path(p),'PATH')

    def test_full_pass_hashes_and_input_immutability(self):
        r=responses(); before=copy.deepcopy(r); result=c.validate_pass(r,expected())
        self.assertEqual(result['normal_body_hashes'][DOC],c.body(dataset()[4][0]['content']))
        self.assertEqual(r,before)

    def test_handshake_pins_caps_and_type_confusion(self):
        for key,value in [('supported',False),('project_id',uid(90)),('migration_epoch',0),('migration_epoch',True),
            ('server_protocol_version',2),('supported_protocol_versions',[3,3]),('server_capabilities',list(c.CAPABILITIES)[:-1]),
            ('contract_version','0.3.0'),('server_contract_sha256','0'*64)]:
            v=dataset();v[1][key]=value
            with self.subTest(key=key): self.reject(lambda:c.validate_pass(responses(v),expected()))

    def test_subject_owner_settings_and_project_mismatch(self):
        for index,key,value in [(0,'id',uid(99)),(2,'owner_id',uid(99)),(2,'is_deleted',True),
            (3,'migration_epoch',2),(3,'project_sync_mode','LEGACY'),(4,'project_id',uid(99))]:
            v=dataset();(v[index] if index == 0 else v[index][0])[key]=value
            self.reject(lambda:c.validate_pass(responses(v),expected()))

    def test_required_missing_null_and_separate_revisions(self):
        for index,key,value in [(4,'structure_revision',None),(4,'revision',0),(5,'revision',True),(6,'revision',1.0),
            (4,'content',None),(4,'updated_at',None),(5,'deleted_at','missing'),(6,'parent_folder_id','missing')]:
            v=dataset()
            if value == 'missing': del v[index][0][key]
            else: v[index][0][key]=value
            self.reject(lambda:c.validate_pass(responses(v),expected()))

    def test_deleted_null_correlation_for_docs_and_folders(self):
        for table in ('documents','folders'):
            row=copy.deepcopy(dataset()[4 if table == 'documents' else 5][0])
            for deleted,at,valid in [(False,None,True),(True,DATE,True),(False,DATE,False),(True,None,False)]:
                row.update(is_deleted=deleted,deleted_at=at)
                if valid:c.row(table,row,PROJECT)
                else:self.reject(lambda:c.row(table,row,PROJECT))

    def test_relationship_cycle_orphan_and_path_mismatch(self):
        for index,key,value in [(5,'parent_folder_id',ROOT),(4,'parent_folder_id',uid(88)),(4,'relative_path','wrong/가.txt')]:
            v=dataset();v[index][0][key]=value
            self.reject(lambda:c.validate_pass(responses(v),expected()))

    def test_normalized_path_collision(self):
        v=dataset();v[4][0].update(name='é',relative_path='합성/é');v[4][1].update(name='e\u0301',relative_path='합성/e\u0301')
        self.reject(lambda:c.validate_pass(responses(v),expected()),'PATH_COLLISION')

    def test_order_duplicate_missing_and_wrong_child(self):
        for change in ('duplicate','missing','unknown','coverage'):
            v=dataset()
            if change == 'duplicate':v[6][1]['children']=[DOC,DOC]
            elif change == 'missing':v[6][1]['children']=[DOC]
            elif change == 'unknown':v[6][1]['children']=[DOC,uid(88)]
            else:v[6].pop()
            self.reject(lambda:c.validate_pass(responses(v),expected()))

    def test_duplicate_entity_and_order_cross_kind(self):
        for change in ('entity','order'):
            v=dataset()
            if change == 'entity':v[4][1]['document_id']=DOC
            else:v[6][0]['tree_order_id']=DOC
            self.reject(lambda:c.validate_pass(responses(v),expected()),'DUPLICATE_ENTITY')

    def test_reference_and_target_are_not_filled_from_observation(self):
        e=expected();e.target['reference_ids']=[uid(80)]
        self.reject(lambda:c.validate_pass(responses(),e),'REFERENCE_ROWS')
        e=expected();e.target['members']['documents'][0]['revision']=2
        self.reject(lambda:c.validate_pass(responses(),e),'TARGET_CHANGED')

    def test_reference_expected_row_change_blocks_even_if_ids_match(self):
        e=expected();e.target['reference_rows']['tree_orders'][0]['revision']=2
        self.reject(lambda:c.validate_pass(responses(),e),'TARGET_CHANGED')

    def test_member_cannot_escape_new_root_scope(self):
        v=dataset();v[4][0].update(parent_folder_id=None,relative_path='가.txt')
        v[6][0]['children'].append(DOC);v[6][1]['children'].remove(DOC)
        self.reject(lambda:c.validate_pass(responses(v),expected(v)),'TARGET_SCOPE')

    def test_expected_missing_reference_rows_or_member_reference_overlap(self):
        e=expected();del e.target['reference_rows']
        self.reject(e.validate,'KEYS')
        e=expected();e.target['reference_ids'].append(DOC)
        self.reject(e.validate,'TARGET_ROLE')

    def test_special_context_preserves_unverified_fields(self):
        v=dataset(); special=dict(project_id=PROJECT,document_id=uid(60),relative_path='__antigravity__/state',content=None,updated_at='not-a-date')
        v[4].append(special)
        result=c.validate_pass(responses(v),expected())
        self.assertEqual(result['context_only_ids'],[uid(60)])
        self.assertNotIn(uid(60),result['normal_body_hashes'])
        self.assertIn(b'not-a-date',result['comparison'])

    def test_full_count_single_page_rules(self):
        for n,header in [(0,'*/0'),(0,'0-0/0'),(1,'0-0/1'),(10000,'0-9999/10000')]:c.count_header(header,n)
        for n,header in [(2,'0-1/*'),(2,'0-1/3'),(2,None),(0,'*/*'),(10001,'0-10000/10001')]:self.reject(lambda:c.count_header(header,n))


class HandoffTests(unittest.TestCase):
    reject = ContractTests.reject

    def test_complete_reference_graph_never_grants_authority(self):
        files,e=envelope(); before=copy.deepcopy(files); r=c.review_handoff(files)
        self.assertTrue(r['reference_graph_reviewed'])
        self.assertFalse(r['received_independent_claims_trusted'])
        for key in ('baseline_ready','baseline_applied','execution_allowed','body_semantics_verified','creation_semantics_verified'):self.assertFalse(r[key])
        self.assertEqual(r['missing_evidence_ids'],['missing-old-time']);self.assertEqual(files,before)

    def test_partial_observation_and_absent_evidence_stay_missing(self):
        files,e=envelope();e['observations'][0].update(response_ref=None,http_status=None)
        self.assertTrue(c.review_handoff(repack(files,e))['reference_graph_reviewed'])
        e['evidence']['absent']['state']='not_applicable'
        self.reject(lambda:c.review_handoff(repack(files,e)),'EVIDENCE_NA')

    def test_artifact_raw_hash_not_reencoded_hash(self):
        files,e=envelope();files['rows.json']=files['rows.json']+b' '
        self.reject(lambda:c.review_handoff(files),'ARTIFACT_HASH')

    def test_target_file_disagreement_is_not_repaired(self):
        files,e=envelope();e['target']['root_id']=uid(77)
        self.reject(lambda:c.review_handoff(repack(files,e)),'TARGET_ARTIFACT')

    def test_target_binding_and_entity_pointer_id_project(self):
        for change in ('binding','position','project'):
            files,e=envelope()
            if change == 'binding':e['target']['binding']=dict(e['binding'],account_id=uid(90))
            elif change == 'position':e['target']['members'][1]['source_refs'][0]['json_pointer']='/4/1'
            else:
                rows=c.strict_json(files['rows.json']);rows[4][0]['project_id']=uid(90);files['rows.json']=c.json_bytes(rows)
            self.reject(lambda:c.review_handoff(repack(files,e,target=True)))

    def test_bad_paths_roles_extra_files_and_artifact_duplicates(self):
        for change in ('path','role','extra','duplicate'):
            files,e=envelope()
            if change == 'path':e['artifacts'][0]['path']='../target.json'
            elif change == 'role':e['artifacts'][0]['role']='unknown'
            elif change == 'extra':files['unexpected.txt']=b'extra'
            else:e['artifacts'].append(copy.deepcopy(e['artifacts'][0]))
            self.reject(lambda:c.review_handoff(repack(files,e)))

    def test_artifact_unicode_case_collision(self):
        files,e=envelope();files['TARGET.json']=files['target.json']
        e['artifacts'].append(dict(e['artifacts'][0],artifact_id='other',path='TARGET.json'))
        self.reject(lambda:c.review_handoff(repack(files,e)),'ARTIFACT_PATH')

    def test_missing_id_and_evidence_spaces_do_not_alias(self):
        for change in ('unresolved','alias','observation'):
            files,e=envelope()
            if change == 'unresolved':e['evidence']['absent']['missing_evidence_id']='absent'
            elif change == 'alias':e['evidence']['missing-old-time']=e['evidence'].pop('absent')
            else:e['observations'][0]['evidence_ids']=['missing-old-time']
            self.reject(lambda:c.review_handoff(repack(files,e)))

    def test_header_cannot_be_fabricated_from_raw_count(self):
        files,e=envelope();e['evidence']['range'].update(value=2,source_ref=dict(artifact_id='rows',json_pointer='/4'))
        self.reject(lambda:c.review_handoff(repack(files,e)),'EVIDENCE_HEADER')

    def test_derived_count_and_local_clock_are_distinct(self):
        files,e=envelope();e['evidence']['count']['value']=3
        self.reject(lambda:c.review_handoff(repack(files,e)),'DERIVED_COUNT')
        files,e=envelope();e['evidence']['time']['source_ref']=dict(artifact_id='rows',json_pointer='/0/id')
        self.reject(lambda:c.review_handoff(repack(files,e)),'EVIDENCE_CLOCK')

    def test_creation_position_batch_operation_and_duplicate(self):
        for change in ('position','batch','operation','duplicate'):
            files,e=envelope()
            if change == 'position':e['creation'][0]['request_index']=9
            elif change == 'batch':e['creation'][0]['batch_id']=uid(70)
            elif change == 'operation':e['creation'][0]['operation_ids']=[uid(70)]
            else:e['creation'].append(copy.deepcopy(e['creation'][0]))
            self.reject(lambda:c.review_handoff(repack(files,e)))

    def test_phase_indexes_body_hash_and_partial_status(self):
        for changes in (dict(phase='B',request_index=8),dict(phase='create',request_index=1),
            dict(request_body_sha256='0'*64),dict(response_ref=None,http_status=200)):
            files,e=envelope();e['observations'][0].update(changes)
            self.reject(lambda:c.review_handoff(repack(files,e)))

    def test_authority_and_binding_contract_injection(self):
        files,e=envelope();e['authority']['baseline_ready']=True
        self.reject(lambda:c.review_handoff(repack(files,e)),'AUTHORITY')
        files,e=envelope();e['binding']['epoch']=0
        self.reject(lambda:c.review_handoff(repack(files,e,target=True)),'INTEGER')

    def test_checks_unverified_null_and_duplicate_ids(self):
        files,e=envelope();e['checks'][0]['independent']['state']='unverified'
        self.reject(lambda:c.review_handoff(repack(files,e)),'UNVERIFIED_VALUE')
        files,e=envelope();e['checks'].append(copy.deepcopy(e['checks'][0]))
        self.reject(lambda:c.review_handoff(repack(files,e)),'CHECK_ID')

    def test_malformed_shapes_fail_with_safe_codes(self):
        for key in ('binding','target','creation','observations','checks','evidence','missing_evidence'):
            files,e=envelope();e[key]=None
            self.reject(lambda:c.review_handoff(repack(files,e)))


if __name__ == '__main__': unittest.main()
