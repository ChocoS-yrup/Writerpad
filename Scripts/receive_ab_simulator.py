"""A/B scheduling and time/usage policy over concrete synthetic doubles only.

No callable network transport, real clock, credential store or baseline adapter.
Journal double serializes and reads back every update; not a production disk WAL.
"""
from dataclasses import dataclass
import copy
import threading

from receive_contract_offline import (ContractError, Expected, TABLES, CONTRACT_SHA,
    need, integer, identifier, json_bytes, strict_json, sha, validate_pass, validate_response, closed_shape)


@dataclass
class FakeClock:
    utc_ms: int
    mono_ms: int = 0
    boot: str = 'synthetic-boot'
    foreground: bool = True
    session: str = 'synthetic-session'

    def advance(self, milliseconds):
        integer(milliseconds)
        self.utc_ms += milliseconds
        self.mono_ms += milliseconds


@dataclass(frozen=True)
class Timing:
    request_ms: int
    pass_ms: int
    interpass_ms: int
    preapply_ms: int
    local_apply_ms: int
    total_ms: int
    not_before_utc_ms: int
    expires_utc_ms: int
    max_response_bytes: int = 4 * 1024 * 1024
    max_run_bytes: int = 32 * 1024 * 1024

    def validate(self):
        for key, value in vars(self).items():
            integer(value, 0 if key == 'not_before_utc_ms' else 1)
        need(self.not_before_utc_ms < self.expires_utc_ms, 'WINDOW')
        need(self.max_response_bytes <= 4*1024*1024 and self.max_response_bytes <= self.max_run_bytes <= 32*1024*1024, 'SIZE_POLICY')


@dataclass(frozen=True)
class MockResponse:
    raw: bytes
    status: int = 200
    content_range: str = None
    delay_ms: int = 1
    persistence_ms: int = 0
    interrupt: str = None  # restart, background, session, utc_back, mono_back, lost


class SyntheticExchange:
    def __init__(self, responses):
        need(type(responses) is list and all(type(r) is MockResponse for r in responses), 'MOCK_ONLY')
        self.responses = copy.deepcopy(responses)
        self.calls = []

    def take(self, request, journal, clock):
        need(journal.read()['http_used'] == len(self.calls)+1, 'RESERVATION_REQUIRED')
        self.calls.append(copy.deepcopy(request))
        need(len(self.responses) >= len(self.calls), 'MOCK_MISSING')
        response = self.responses[len(self.calls)-1]
        clock.advance(response.delay_ms)
        if response.interrupt == 'restart': clock.boot = 'other-boot'
        elif response.interrupt == 'background': clock.foreground = False
        elif response.interrupt == 'session': clock.session = 'other-session'
        elif response.interrupt == 'utc_back': clock.utc_ms -= response.delay_ms + 1
        elif response.interrupt == 'mono_back': clock.mono_ms -= response.delay_ms + 1
        elif response.interrupt == 'lost': raise ContractError('RESPONSE_LOST')
        elif response.interrupt is not None: raise ContractError('MOCK_INTERRUPT')
        return response


class SyntheticJournal:
    """Serializable persistence double; failure/no-op injection verifies caller readback."""
    def __init__(self, restored=None):
        self.blob = restored if restored is not None else json_bytes({'run_id':None,'binding':None,
            'status':'unused','http_used':0,'auth_used':0,'events':[]})
        self.lock = threading.Lock()
        self.skip = None
        self.fail_before = None
        self.fail_after = None
        self.poisoned = False

    def read(self):
        state = strict_json(self.blob, 70*1024*1024)  # Bounded 32 MiB raw is hex encoded.
        need(type(state) is dict and set(state) == {'run_id','binding','status','http_used','auth_used','events'}, 'JOURNAL')
        integer(state['http_used'],0,14); integer(state['auth_used'],0,2)
        need(type(state['events']) is list and state['status'] in ('unused','running','stopped','finished'), 'JOURNAL')
        return state

    def write(self, state, operation):
        if self.fail_before == operation:
            self.poisoned = True; raise ContractError('JOURNAL_WRITE')
        data = json_bytes(state)
        if self.skip != operation: self.blob = data
        if self.fail_after == operation:
            self.poisoned = True; raise ContractError('JOURNAL_UNCERTAIN')
        if self.blob != data:
            self.poisoned = True; raise ContractError('JOURNAL_READBACK')


class ABRunner:
    def __init__(self, expected, timing, run_id, *, synthetic=True):
        need(synthetic is True and type(expected) is Expected and type(timing) is Timing, 'SYNTHETIC_ONLY')
        expected.validate(); timing.validate(); identifier(run_id)
        self.expected = copy.deepcopy(expected)
        self.timing = timing
        self.run_id = run_id
        self.binding = sha(json_bytes({'account':expected.account,'project':expected.project,'target':expected.target,'project_state_field':expected.project_state_field,'timing':vars(timing)}))

    def _request(self, ordinal):
        n = ordinal % 7
        paths = ['/auth/v1/user','/rest/v1/rpc/get_sync_handshake'] + ['/rest/v1/'+t for t in TABLES]
        payload = json_bytes({'p_project_id':self.expected.project,'p_contract_sha256':CONTRACT_SHA}) if n == 1 else b''
        return {'phase':'A' if ordinal < 7 else 'B','request_index':n+1,
            'method':'POST' if n == 1 else 'GET','path':paths[n],
            'query':{'project_id':'eq.'+self.expected.project,'select':'*','limit':'10000'} if n >= 2 else {},
            'headers':{'Prefer':'count=exact'} if n >= 2 else {},'body_sha256':sha(payload)}

    @closed_shape
    def run(self, exchange, journal, clock, *, interpass_delay_ms=0,
            comparison_ms=0, preapply_delay_ms=0, local_apply_ms=0, reservation_ms=0):
        need(type(exchange) is SyntheticExchange and type(journal) is SyntheticJournal and type(clock) is FakeClock, 'SYNTHETIC_ONLY')
        for v in (interpass_delay_ms,comparison_ms,preapply_delay_ms,local_apply_ms,reservation_ms): integer(v)
        self.timing.validate()
        need(not exchange.calls, 'EXCHANGE_USED')
        need(journal.lock.acquire(blocking=False), 'BUSY')
        state = None
        try:
            need(not journal.poisoned, 'JOURNAL_POISONED')
            state = journal.read()
            need(state == {'run_id':None,'binding':None,'status':'unused','http_used':0,'auth_used':0,'events':[]}, 'RUN_REUSE')
            need(clock.foreground and type(clock.boot) is str and type(clock.session) is str, 'LIFECYCLE')
            integer(clock.utc_ms); integer(clock.mono_ms)
            need(self.timing.not_before_utc_ms <= clock.utc_ms < self.timing.expires_utc_ms, 'WINDOW')
            boot, session = clock.boot, clock.session
            first = last_mono = clock.mono_ms
            last_utc = clock.utc_ms
            def check():
                nonlocal last_mono, last_utc
                integer(clock.utc_ms); integer(clock.mono_ms)
                need(clock.foreground and clock.boot == boot and clock.session == session, 'LIFECYCLE_CHANGED')
                need(clock.utc_ms >= last_utc and clock.mono_ms >= last_mono, 'CLOCK_BACKWARD')
                need(clock.utc_ms < self.timing.expires_utc_ms, 'EXPIRED')
                need(clock.mono_ms-first < self.timing.total_ms, 'TOTAL_TIMEOUT')
                last_mono, last_utc = clock.mono_ms, clock.utc_ms
            state.update(run_id=self.run_id,binding=self.binding,status='running')
            journal.write(state,'claim')
            a_result = None; total_bytes = 0; last_response = None
            for pass_index in range(2):
                if pass_index:
                    clock.advance(interpass_delay_ms); check()
                    need(clock.mono_ms-last_response < self.timing.interpass_ms,'INTERPASS_TIMEOUT')
                pass_start = clock.mono_ms; collected = []
                for n in range(7):
                    check(); need(clock.mono_ms-pass_start < self.timing.pass_ms,'PASS_TIMEOUT')
                    ordinal = pass_index*7+n; req = self._request(ordinal)
                    request_start = clock.mono_ms
                    state['http_used'] += 1
                    if n == 0: state['auth_used'] += 1
                    need(state['http_used'] <= 14 and state['auth_used'] <= 2,'QUOTA')
                    event = {'request':req,'reservation_id':self.run_id+':'+str(ordinal+1),
                        'reserved_utc_ms':clock.utc_ms,'reserved_mono_ms':clock.mono_ms}
                    state['events'].append(event)
                    journal.write(state,'reserve:%d'%(ordinal+1))
                    clock.advance(reservation_ms); check()
                    need(clock.mono_ms-request_start < self.timing.request_ms,'REQUEST_TIMEOUT')
                    need(clock.mono_ms-pass_start < self.timing.pass_ms,'PASS_TIMEOUT')
                    event['started_utc_ms'], event['started_mono_ms'] = clock.utc_ms, clock.mono_ms
                    response = exchange.take(req,journal,clock)
                    check(); last_response = clock.mono_ms
                    event.update(received_utc_ms=clock.utc_ms,received_mono_ms=clock.mono_ms)
                    need(clock.mono_ms-request_start < self.timing.request_ms,'REQUEST_TIMEOUT')
                    need(type(response.raw) is bytes and len(response.raw) <= self.timing.max_response_bytes,'RESPONSE_SIZE')
                    total_bytes += len(response.raw); need(total_bytes <= self.timing.max_run_bytes,'RUN_SIZE')
                    # Status failures retain only safe length/hash metadata. Never persist an error body.
                    event.update(http_status=response.status,raw_sha256=sha(response.raw),byte_count=len(response.raw))
                    try:
                        parsed = validate_response(n,response,self.expected)
                    except ContractError:
                        journal.write(state,'error:%d'%(ordinal+1)); raise
                    # Synthetic private evidence includes raw bytes as hex. Export summary never includes it.
                    event.update(raw_hex=response.raw.hex(),content_range=response.content_range,
                        row_count=len(parsed) if n >= 2 else None)
                    clock.advance(response.persistence_ms); check()
                    need(clock.mono_ms-request_start < self.timing.request_ms,'REQUEST_TIMEOUT')
                    need(clock.mono_ms-pass_start < self.timing.pass_ms,'PASS_TIMEOUT')
                    event.update(verified_utc_ms=clock.utc_ms,verified_mono_ms=clock.mono_ms)
                    journal.write(state,'response:%d'%(ordinal+1))
                    collected.append(response)
                result = validate_pass(collected,self.expected)
                check(); need(clock.mono_ms-pass_start < self.timing.pass_ms,'PASS_TIMEOUT')
                if pass_index == 0: a_result = result
                else:
                    clock.advance(comparison_ms); check()
                    need(result['comparison'] == a_result['comparison'],'AB_CHANGED')
            clock.advance(preapply_delay_ms); check()
            need(clock.mono_ms-last_response < self.timing.preapply_ms,'PREAPPLY_TIMEOUT')
            # Only a fake elapsed apply interval, no storage adapter or actual baseline object.
            apply_start = clock.mono_ms
            state['events'].append({'phase':'local_policy_probe','started_utc_ms':clock.utc_ms,'started_mono_ms':clock.mono_ms})
            journal.write(state,'local_start')
            clock.advance(local_apply_ms); check()
            need(clock.mono_ms-apply_start < self.timing.local_apply_ms,'LOCAL_APPLY_TIMEOUT')
            state['events'][-1].update(completed_utc_ms=clock.utc_ms,completed_mono_ms=clock.mono_ms)
            state['status'] = 'finished'; journal.write(state,'finish')
            return {'synthetic_policy_passed':True,'sequential_comparison_passed':True,
                'http_reserved':state['http_used'],'auth_reserved':state['auth_used'],
                'context_only_ids':result['context_only_ids'],'atomic_snapshot':False,
                'latest_at_apply_guaranteed':False,'baseline_ready':False,'baseline_applied':False,
                'execution_allowed':False,'app_binding_created':False,'editing_allowed':False,
                'sending_allowed':False,'automatic_receive_allowed':False}
        except ContractError:
            # Preserve reservations and partial evidence. No refund, replay, reset or error-body logging.
            if state is not None and state['run_id'] == self.run_id and state['status'] == 'running':
                try:
                    persisted = journal.read()
                    if persisted['run_id'] == self.run_id:
                        persisted['status'] = 'stopped'; journal.write(persisted,'stop')
                except ContractError: journal.poisoned = True
            raise
        finally:
            journal.lock.release()
