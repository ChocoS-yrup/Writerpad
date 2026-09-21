import copy
from dataclasses import replace
import socket
import unittest
from unittest.mock import patch

from receive_fixtures import c,a,uid,RUN,DATE,dataset,expected,responses,timing


class PolicyTests(unittest.TestCase):
    def setup_run(self, values=None, limits=None, exp=None):
        self.exchange=a.SyntheticExchange(values if values is not None else responses()+responses())
        self.journal=a.SyntheticJournal();self.clock=a.FakeClock(1000)
        self.runner=a.ABRunner(exp if exp is not None else expected(),limits if limits is not None else timing(),RUN)

    def run_policy(self, **kw): return self.runner.run(self.exchange,self.journal,self.clock,**kw)

    def fails(self,code=None,**kw):
        with self.assertRaises(c.ContractError) as error:self.run_policy(**kw)
        if code:self.assertEqual(error.exception.code,code)
        return error.exception.code

    def test_normal_fourteen_requests_with_two_auth_and_no_authority(self):
        self.setup_run()
        with patch.object(socket,'socket',side_effect=AssertionError('no network')):
            result=self.run_policy()
        self.assertTrue(result['synthetic_policy_passed']);self.assertTrue(result['sequential_comparison_passed'])
        self.assertEqual((result['http_reserved'],result['auth_reserved']),(14,2))
        for key in ('baseline_ready','baseline_applied','execution_allowed','app_binding_created','editing_allowed','sending_allowed','automatic_receive_allowed','atomic_snapshot','latest_at_apply_guaranteed'):
            self.assertFalse(result[key])
        calls=self.exchange.calls
        self.assertEqual([r['request_index'] for r in calls],list(range(1,8))*2)
        self.assertEqual([r['phase'] for r in calls],['A']*7+['B']*7)
        self.assertEqual(sum(r['method']=='POST' for r in calls),2)
        self.assertTrue(all(r['path']=='/rest/v1/rpc/get_sync_handshake' for r in calls if r['method']=='POST'))
        self.assertEqual(calls[2]['query'],{'project_id':'eq.'+self.runner.expected.project,'select':'*','limit':'10000'})

    def test_raw_hashes_and_all_four_times_preserved(self):
        self.setup_run();self.run_policy(reservation_ms=2)
        state=self.journal.read();self.assertEqual(state['status'],'finished')
        for event in state['events'][:14]:
            self.assertEqual(c.sha(bytes.fromhex(event['raw_hex'])),event['raw_sha256'])
            self.assertEqual(event['started_mono_ms']-event['reserved_mono_ms'],2)
            self.assertLessEqual(event['received_mono_ms'],event['verified_mono_ms'])
            self.assertIn('reservation_id',event)
        self.assertIn('completed_mono_ms',state['events'][-1])

    def test_key_table_row_and_capability_order_ignored(self):
        b=dataset();b[4].reverse();b[6].reverse();b[1]['server_capabilities'].reverse();b[1]['supported_protocol_versions'].reverse()
        rs=responses(b)
        rs=[replace(r,raw=r.raw.rstrip()+b'  \n') for r in rs]
        self.setup_run(responses()+rs);self.assertTrue(self.run_policy()['sequential_comparison_passed'])
        self.assertNotEqual(self.journal.read()['events'][0]['raw_sha256'],self.journal.read()['events'][7]['raw_sha256'])

    def test_unchanged_unknown_fields_are_compared_without_apply_claim(self):
        v=dataset();v[2][0]['unknown']={'future':[1,None,'x']}
        self.setup_run(responses(v)+responses(v));self.assertFalse(self.run_policy()['baseline_ready'])

    def test_ab_unknown_missing_date_and_capability_changes_stop(self):
        for change in ('unknown','date','capability','field_missing'):
            av=dataset();bv=dataset()
            if change=='unknown':bv[2][0]['future']=True
            elif change=='date':
                av[2][0]['updated_at']=DATE
                bv[2][0]['updated_at']='2026-09-14T09:00:00.123456+09:00'
            elif change=='capability':bv[1]['server_capabilities'].append('future_capability')
            else:av[2][0]['future']=None
            self.setup_run(responses(av)+responses(bv));self.fails('AB_CHANGED')
            self.assertEqual(self.journal.read()['http_used'],14)

    def test_body_revision_and_children_changes_block_target(self):
        for index,key,value in [(4,'content','changed'),(4,'revision',2),(6,'children',list(reversed(dataset()[6][1]['children'])))]:
            bv=dataset();bv[index][1 if index==6 else 0][key]=value
            self.setup_run(responses()+responses(bv));self.fails('TARGET_CHANGED')

    def test_same_incomplete_graph_in_both_passes_does_not_pass(self):
        v=dataset();v[6][1]['children'].pop()
        self.setup_run(responses(v)*2);self.fails('ORDER_MEMBERSHIP')
        self.assertEqual(len(self.exchange.calls),7)

    def test_special_field_change_is_visible_not_body_verified(self):
        v=dataset();v[4].append(dict(project_id=self_project(),document_id=uid(60),relative_path='__antigravity__/x',content=None))
        b=copy.deepcopy(v);b[4][-1]['content']='new'
        self.setup_run(responses(v)+responses(b));self.fails('AB_CHANGED')

    def test_invalid_subject_handshake_project_settings_fail_before_next_request(self):
        for index,key,value,code in [(0,'id',uid(99),'SUBJECT'),(1,'migration_epoch',2,'EPOCH'),
            (2,'owner_id',uid(99),'OWNER'),(3,'project_sync_mode','LEGACY','SETTINGS')]:
            v=dataset();(v[index] if index<2 else v[index][0])[key]=value
            self.setup_run(responses(v)+responses());self.fails(code)
            self.assertEqual(len(self.exchange.calls),index+1)
            self.assertEqual(self.journal.read()['http_used'],index+1)

    def test_http_failure_redacts_error_body_and_preserves_charge(self):
        rs=responses()+responses();rs[1]=a.MockResponse(b'{"access_token":"SYNTHETIC-SECRET"}',status=401)
        self.setup_run(rs);self.fails('HTTP_STATUS')
        state=self.journal.read();self.assertEqual((state['http_used'],state['auth_used']),(2,1))
        self.assertNotIn(b'SYNTHETIC-SECRET',self.journal.blob)
        self.assertNotIn(b'SYNTHETIC-SECRET'.hex().encode(),self.journal.blob)
        self.assertIn('raw_sha256',state['events'][-1]);self.assertEqual(state['status'],'stopped')

    def test_redirect_and_wrong_success_status_are_not_followed(self):
        for status in (301,302,307,204,206):
            rs=responses()*2;rs[0]=replace(rs[0],status=status)
            self.setup_run(rs);self.fails('HTTP_STATUS');self.assertEqual(len(self.exchange.calls),1)

    def test_table_206_is_allowed_only_with_complete_count(self):
        rs=responses()*2;rs[4]=replace(rs[4],status=206)
        self.setup_run(rs);self.assertTrue(self.run_policy()['synthetic_policy_passed'])
        rs[4]=replace(rs[4],content_range='0-1/3')
        self.setup_run(rs);self.fails('COUNT');self.assertEqual(len(self.exchange.calls),5)

    def test_partial_json_and_count_fail_without_page_or_retry(self):
        for raw,header in [(b'[','0-0/1'),(responses()[4].raw,None)]:
            rs=responses()*2;rs[4]=replace(rs[4],raw=raw,content_range=header)
            self.setup_run(rs);self.fails();self.assertEqual(len(self.exchange.calls),5)
            self.assertEqual(self.journal.read()['http_used'],5)

    def test_response_and_aggregate_size_caps(self):
        rs=responses()*2
        self.setup_run(rs,timing(max_response_bytes=10,max_run_bytes=100));self.fails('RESPONSE_SIZE')
        maximum=max(len(r.raw) for r in rs)
        self.setup_run(rs,timing(max_response_bytes=maximum,max_run_bytes=maximum+1));self.fails('RUN_SIZE')
        self.assertGreater(self.journal.read()['http_used'],1)

    def test_each_required_time_value_missing_zero_bool_or_float_blocks(self):
        for name in ('request_ms','pass_ms','interpass_ms','preapply_ms','local_apply_ms','total_ms','expires_utc_ms'):
            for value in (None,0,True,1.0):
                with self.subTest(name=name,value=value),self.assertRaises(c.ContractError):self.setup_run(limits=timing(**{name:value}))
        for value in (None,True,-1):
            with self.assertRaises(c.ContractError):self.setup_run(limits=timing(not_before_utc_ms=value))

    def test_absolute_window_before_equal_expiry_and_valid_start(self):
        for now in (999,6000):
            self.setup_run();self.clock.utc_ms=now;self.fails('WINDOW');self.assertEqual(len(self.exchange.calls),0)
        self.setup_run(limits=timing(expires_utc_ms=1014));self.fails('EXPIRED')
        self.setup_run(limits=timing(expires_utc_ms=1015));self.assertTrue(self.run_policy()['synthetic_policy_passed'])

    def test_request_timeout_includes_reservation_and_persistence(self):
        for delay,persist,reserve in [(100,0,0),(1,99,0),(1,0,100)]:
            rs=responses()*2;rs[0]=replace(rs[0],delay_ms=delay,persistence_ms=persist)
            self.setup_run(rs);self.fails('REQUEST_TIMEOUT',reservation_ms=reserve)
            self.assertEqual(self.journal.read()['http_used'],1)
            self.assertEqual(len(self.exchange.calls),0 if reserve==100 else 1)
        rs=responses()*2;rs[0]=replace(rs[0],delay_ms=99)
        self.setup_run(rs);self.assertTrue(self.run_policy()['synthetic_policy_passed'])

    def test_pass_deadline_equal_and_reservation_no_send(self):
        self.setup_run(limits=timing(pass_ms=7));self.fails('PASS_TIMEOUT');self.assertEqual(len(self.exchange.calls),7)
        self.setup_run(limits=timing(pass_ms=8));self.assertTrue(self.run_policy()['synthetic_policy_passed'])
        self.setup_run(limits=timing(pass_ms=2));self.fails('PASS_TIMEOUT',reservation_ms=2)
        self.assertEqual(len(self.exchange.calls),0);self.assertEqual(self.journal.read()['http_used'],1)

    def test_interpass_includes_a_last_response_persistence(self):
        rs=responses()*2;rs[6]=replace(rs[6],persistence_ms=30)
        self.setup_run(rs);self.fails('INTERPASS_TIMEOUT',interpass_delay_ms=70);self.assertEqual(len(self.exchange.calls),7)
        self.setup_run(rs);self.assertTrue(self.run_policy(interpass_delay_ms=69)['synthetic_policy_passed'])

    def test_preapply_includes_b_persistence_comparison_and_wait(self):
        rs=responses()*2;rs[13]=replace(rs[13],persistence_ms=30)
        self.setup_run(rs);self.fails('PREAPPLY_TIMEOUT',comparison_ms=20,preapply_delay_ms=50)
        self.setup_run(rs);self.assertTrue(self.run_policy(comparison_ms=20,preapply_delay_ms=49)['synthetic_policy_passed'])

    def test_local_apply_time_is_only_probe_and_preserves_partial_marker(self):
        self.setup_run();self.fails('LOCAL_APPLY_TIMEOUT',local_apply_ms=100)
        self.assertEqual(self.journal.read()['events'][-1]['phase'],'local_policy_probe')
        self.assertNotIn('completed_mono_ms',self.journal.read()['events'][-1])
        self.setup_run();self.assertTrue(self.run_policy(local_apply_ms=99)['synthetic_policy_passed'])

    def test_total_deadline_even_when_individual_limits_pass(self):
        self.setup_run(limits=timing(total_ms=14));self.fails('TOTAL_TIMEOUT')
        self.setup_run(limits=timing(total_ms=15));self.assertTrue(self.run_policy()['synthetic_policy_passed'])

    def test_interrupt_lifecycle_session_clock_and_response_loss(self):
        for interruption in ('restart','background','session','utc_back','mono_back','lost'):
            rs=responses()*2;rs[3]=replace(rs[3],interrupt=interruption)
            self.setup_run(rs);self.fails();self.assertEqual(len(self.exchange.calls),4)
            state=self.journal.read();self.assertEqual(state['http_used'],4);self.assertEqual(state['status'],'stopped')

    def test_restart_deserialization_never_reuses_running_stopped_finished(self):
        for status in ('running','stopped','finished'):
            self.setup_run();state=self.journal.read();state.update(run_id=RUN,binding=self.runner.binding,status=status,http_used=1,auth_used=1)
            self.journal=a.SyntheticJournal(c.json_bytes(state));self.fails('RUN_REUSE');self.assertEqual(len(self.exchange.calls),0)

    def test_finished_run_and_fifteenth_response_never_replayed(self):
        self.setup_run(responses()*3);self.run_policy();self.assertEqual(len(self.exchange.calls),14)
        self.exchange=a.SyntheticExchange(responses()*2);self.fails('RUN_REUSE');self.assertEqual(len(self.exchange.calls),0)

    def test_noop_or_failed_reservation_never_sends_and_does_not_refund(self):
        for injection in ('skip','fail_before','fail_after'):
            for operation,charge,calls in [('claim',0,0),('reserve:1',0,0),('reserve:3',2,2)]:
                self.setup_run();setattr(self.journal,injection,operation);self.fails()
                self.assertEqual(len(self.exchange.calls),calls)
                self.assertTrue(self.journal.poisoned)
                minimum=charge+(1 if injection=='fail_after' and operation.startswith('reserve') else 0)
                self.assertEqual(self.journal.read()['http_used'],minimum)

    def test_response_and_finish_write_failures_do_not_return_success(self):
        for operation,calls in [('response:1',1),('response:7',7),('local_start',14),('finish',14)]:
            self.setup_run();self.journal.skip=operation;self.fails('JOURNAL_READBACK')
            self.assertEqual(len(self.exchange.calls),calls);self.assertEqual(self.journal.read()['http_used'],calls)

    def test_same_journal_exclusive_lock_and_corruption(self):
        self.setup_run();self.journal.lock.acquire()
        try:self.fails('BUSY')
        finally:self.journal.lock.release()
        self.assertEqual(len(self.exchange.calls),0)
        self.journal.blob=b'{';self.fails('JSON');self.assertEqual(len(self.exchange.calls),0)

    def test_no_arbitrary_transport_or_real_mode(self):
        class UnsafeExchange(a.SyntheticExchange):
            def take(self,*args):raise AssertionError('must never call')
        self.setup_run();self.exchange=UnsafeExchange(responses()*2);self.fails('SYNTHETIC_ONLY')
        with self.assertRaises(c.ContractError):a.ABRunner(expected(),timing(),RUN,synthetic=False)

    def test_caller_expected_mutation_does_not_change_bound_target(self):
        exp=expected();self.setup_run(exp=exp);exp.target['root_id']=uid(99)
        self.assertTrue(self.run_policy()['synthetic_policy_passed'])


def self_project(): return dataset()[2][0]['project_id']


if __name__ == '__main__':unittest.main()
