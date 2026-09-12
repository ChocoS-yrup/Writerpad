-- 격리된 빈 PostgreSQL에만 사용하는 합성 자료. 운영 서버 실행 금지.
begin;
insert into auth.users values ('10000000-0000-0000-0000-000000000001');
insert into public.projects(project_id,owner_id,name) values ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','synthetic');
insert into public.project_members(project_id,user_id,role) values ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','owner');
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',true);
update private.sync_contract_allowlist set enabled=true;
insert into public.project_sync_settings(project_id,project_sync_mode,migration_epoch,contract_enforcement_started_at,active_contract_sha256)
values ('20000000-0000-0000-0000-000000000001','ID_BASED',1,now(),'416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670');

create function pg_temp.request(p_kind text,p_id uuid,p_base bigint,p_action text,p_payload jsonb) returns jsonb language plpgsql as $$
declare
 b uuid := gen_random_uuid(); i jsonb; meta jsonb; caps text[];
begin
 select allowed_client_capabilities into caps from private.sync_contract_allowlist limit 1;
 i:=jsonb_build_object('sequence',1,'batch_id',b,'operation_id',gen_random_uuid(),'entity_kind',p_kind,'entity_id',p_id,'base_revision',p_base,'intent_kind',p_action,'payload',p_payload,'payload_sha256',private.jsonb_rfc8785_sha256(p_payload));
 if p_kind='document' and p_action in ('create','update','delete','restore') then i:=(i-'entity_id')||jsonb_build_object('document_id',p_id); end if;
 meta:=jsonb_build_object('batch_id',b,'writer_device_id','30000000-0000-0000-0000-000000000001','client_build_id','synthetic-test','sync_protocol_version',3,'contract_version','0.2.0','canonical_contract_sha256','416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670','client_capabilities',to_jsonb(caps),'batch_payload_sha256',private.jsonb_rfc8785_sha256(jsonb_build_array(i)));
 return jsonb_build_object('kind',case when p_kind='document' and p_action in ('create','update','delete','restore') then 'document_commit_request' else 'atomic_structure_commit_request' end,'project_id','20000000-0000-0000-0000-000000000001','project_sync_mode','ID_BASED','migration_epoch',1,'batch',meta,'ordered_intents',jsonb_build_array(i));
end $$;
create function pg_temp.send(r jsonb, expected text default 'committed') returns jsonb language plpgsql as $$
declare result jsonb;
begin
 if r->>'kind'='document_commit_request' then result:=public.document_commit(r); else result:=public.atomic_structure_commit(r); end if;
 if result->>'status' is distinct from expected then raise exception 'expected %, response %',expected,result; end if;
 return result;
end $$;
create function pg_temp.combine(parts jsonb[]) returns jsonb language plpgsql as $$
declare r jsonb:=parts[1]; intents jsonb:='[]'::jsonb; part jsonb; i integer:=0;
begin
 foreach part in array parts loop
   i:=i+1;
   intents:=intents||jsonb_build_array((part->'ordered_intents'->0)||jsonb_build_object('sequence',i,'batch_id',r->'batch'->'batch_id'));
 end loop;
 r:=jsonb_set(r,'{ordered_intents}',intents);
 return jsonb_set(r,'{batch,batch_payload_sha256}',to_jsonb(private.jsonb_rfc8785_sha256(intents)));
end $$;
create function pg_temp.body(p_deleted boolean default false) returns jsonb language sql as $$
select jsonb_build_object('name','empty.txt','parent_folder_id','40000000-0000-0000-0000-000000000001','structure_revision',1,'content','','content_byte_count',0,'content_sha256',private.content_sha256(''),'is_deleted',p_deleted)
$$;

do $$
declare
 folder uuid:='40000000-0000-0000-0000-000000000001'; doc uuid:='50000000-0000-0000-0000-000000000001'; ord uuid:='60000000-0000-0000-0000-000000000001';
 marker uuid; h bytea; r jsonb; result jsonb; content text; baseline bigint; bad jsonb;
begin
 perform pg_temp.send(pg_temp.request('folder',folder,0,'create',jsonb_build_object('name','volume','parent_folder_id',null)));
 r:=pg_temp.request('document',doc,0,'create',pg_temp.body());
 perform pg_temp.send(r); perform pg_temp.send(r,'replayed');
 if (select count(*) from public.document_versions where document_id=doc)<>1 then raise exception 'duplicate create'; end if;
 perform pg_temp.send(pg_temp.request('tree_order',ord,0,'reorder',jsonb_build_object('parent_folder_id',folder,'children',jsonb_build_array(doc))));
 -- 순서에 남아 있는 문서 삭제는 원자적으로 거절되어야 한다.
 r:=pg_temp.request('document',doc,1,'delete',pg_temp.body(true));
 result:=public.document_commit(r);
 if result->>'applied'='true' or (select revision from public.documents where document_id=doc)<>1 then raise exception 'referenced deletion accepted'; end if;
 perform pg_temp.send(pg_temp.request('tree_order',ord,1,'reorder',jsonb_build_object('parent_folder_id',folder,'children','[]'::jsonb)));
 perform pg_temp.send(pg_temp.request('document',doc,1,'delete',pg_temp.body(true)));
 perform pg_temp.send(pg_temp.request('document',doc,2,'restore',pg_temp.body(false)));
 perform pg_temp.send(pg_temp.request('document',doc,3,'delete',pg_temp.body(true)));
 h:=extensions.digest(uuid_send('20000000-0000-0000-0000-000000000001'::uuid)||convert_to('__antigravity__/trash-purge.json','UTF8'),'sha1');
 h:=set_byte(h,6,(get_byte(h,6)&15)|80); h:=set_byte(h,8,(get_byte(h,8)&63)|128); marker:=encode(substring(h,1,16),'hex')::uuid;
 content:=jsonb_build_object('version',1,'purged_revisions',jsonb_build_object(doc::text,4),'empty_generation','')::text;
 r:=pg_temp.request('trash_purge',marker,0,'update',jsonb_build_object('content',content));
 perform pg_temp.send(r); perform pg_temp.send(r,'replayed');
 if (select revision from public.documents where document_id=marker)<>1 or (select count(*) from public.document_versions where document_id=marker)<>1 then raise exception 'purge replay duplicated'; end if;
 if not (select is_deleted from public.documents where document_id=doc) or (select count(*) from public.document_versions where document_id=doc)<>4 then raise exception 'purge lost tombstone/history'; end if;
 -- 충돌/잘못된 표식은 원고와 marker revision 모두 유지한다.
 foreach bad in array array[
   pg_temp.request('trash_purge',marker,0,'update',jsonb_build_object('content',content)),
   pg_temp.request('trash_purge',gen_random_uuid(),0,'update',jsonb_build_object('content',content)),
   pg_temp.request('trash_purge',marker,1,'update',jsonb_build_object('content','{"version":1,"purged_revisions":{},"empty_generation":""}')),
   pg_temp.request('trash_purge',marker,1,'update',jsonb_build_object('content','invalid')),
   pg_temp.request('trash_purge',marker,1,'update',jsonb_build_object('content',jsonb_build_object('version',1,'purged_revisions',jsonb_build_object(doc::text,5),'empty_generation','')::text))
 ] loop
   result:=public.atomic_structure_commit(bad);
   if result->>'applied'='true' or (select revision from public.documents where document_id=marker)<>1 then raise exception 'bad purge accepted'; end if;
 end loop;
 -- 복원된 문서의 이전 purge 표식은 유지할 수 있지만 새 revision을 지울 수 없다.
 perform pg_temp.send(pg_temp.request('document',doc,4,'restore',pg_temp.body(false)));
 bad:=pg_temp.request('trash_purge',marker,1,'update',jsonb_build_object('content',jsonb_build_object('version',1,'purged_revisions',jsonb_build_object(doc::text,5),'empty_generation','')::text));
 result:=public.atomic_structure_commit(bad);
 if result->>'applied'='true' then raise exception 'active purge accepted'; end if;
 perform pg_temp.send(pg_temp.request('trash_purge',marker,1,'update',jsonb_build_object('content',content)));
 -- 첫 구조 intent가 성공해도 뒤의 이동이 실패하면 전체를 되돌린다.
 bad:=pg_temp.combine(array[
   pg_temp.request('folder',folder,1,'rename',jsonb_build_object('name','intermediate')),
   pg_temp.request('document',doc,1,'move',jsonb_build_object('parent_folder_id',gen_random_uuid()))
 ]);
 result:=public.atomic_structure_commit(bad);
 if result->>'applied'='true' or (select name from public.folders where folder_id=folder)<>'volume' then raise exception 'partial structure commit'; end if;
 r:=pg_temp.combine(array[
   pg_temp.request('folder',folder,1,'rename',jsonb_build_object('name','volume-final')),
   pg_temp.request('document',doc,1,'move',jsonb_build_object('parent_folder_id',null)),
   pg_temp.request('document',doc,2,'rename',jsonb_build_object('name','moved.txt')),
   pg_temp.request('tree_order',gen_random_uuid(),0,'reorder',jsonb_build_object('parent_folder_id',null,'children',jsonb_build_array(folder,doc)))
 ]);
 perform pg_temp.send(r); perform pg_temp.send(r,'replayed');
 if (select relative_path from public.documents where document_id=doc)<>'moved.txt'
    or (select revision from public.documents where document_id=doc)<>5
    or (select structure_revision from public.documents where document_id=doc)<>3 then raise exception 'structure changed body or path incorrectly'; end if;
 if has_function_privilege('authenticated','private.apply_contract_trash_purge(uuid,uuid,jsonb)','execute') or has_function_privilege('anon','private.apply_contract_trash_purge(uuid,uuid,jsonb)','execute') then raise exception 'private function exposed'; end if;
 perform set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000002',true);
 begin
   perform public.atomic_structure_commit(pg_temp.request('trash_purge',marker,2,'update',jsonb_build_object('content',content)));
   raise exception 'foreign user accepted';
 exception when sqlstate 'P0001' then
   if sqlerrm<>'FORBIDDEN' then raise; end if;
 end;
end $$;
select 'PASS: create/replay/order/delete/restore/purge/replay/rejection/authorization/history/compound-structure/rollback';
rollback;
