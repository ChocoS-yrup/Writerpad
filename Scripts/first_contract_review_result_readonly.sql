-- Staging mhpnszcorfzrvhyondxr 전용, 검토한 한 요청의 결과 조회.
-- SELECT만 사용한다. 빈 결과는 재전송 허가가 아니다.
WITH target AS (
  SELECT '1bd47431-0773-482c-8eb5-ac9e2952b6f4'::uuid AS project_id,
         '45af53f8-ec2c-46b9-bf84-b2d56857fe5c'::uuid AS batch_id
), batches AS (
  SELECT b.batch_id,b.project_id,b.writer_device_id,b.client_build_id,
         b.sync_protocol_version,b.contract_version,b.canonical_contract_sha256,
         b.batch_payload_sha256,b.project_sync_mode,b.migration_epoch,
         b.request_sha256,b.created_at
  FROM public.sync_batches b JOIN target t USING (batch_id,project_id)
), results AS (
  SELECT r.batch_id,r.applied,r.response_sha256,r.recorded_at,r.response
  FROM public.sync_batch_results r JOIN batches b USING (batch_id)
), operations AS (
  SELECT o.operation_id,o.batch_id,o.sequence,o.entity_kind,o.entity_id,
         o.intent_kind,o.base_revision,o.payload_sha256
  FROM public.sync_operations o JOIN target t USING (project_id)
  WHERE o.batch_id=t.batch_id OR o.operation_id IN (
    '07cbb3c7-1773-48c7-8232-dcb6ebe5927b'::uuid,
    '2032a3b1-ec8c-46d9-93ac-f01c7d9980e5'::uuid)
), attempts AS (
  SELECT a.operation_id,a.attempt_number,a.started_at,a.finished_at,a.rpc_name,
         a.outcome,a.request_sha256,a.response_sha256,a.error_code,a.result_revision
  FROM public.sync_operation_attempts a WHERE a.operation_id IN (
    '07cbb3c7-1773-48c7-8232-dcb6ebe5927b'::uuid,
    '2032a3b1-ec8c-46d9-93ac-f01c7d9980e5'::uuid)
), folders AS (
  SELECT f.folder_id,f.parent_folder_id,f.name,f.revision,f.is_deleted
  FROM public.folders f JOIN target t USING (project_id)
  WHERE f.folder_id='4711b2ce-5de9-44ba-80fe-570515839549'::uuid
), orders AS (
  SELECT o.tree_order_id,o.parent_folder_id,o.children,o.revision
  FROM public.tree_orders o JOIN target t USING (project_id)
  WHERE o.tree_order_id='68c1a7b5-0dda-49ba-bc9a-42e92ce2b758'::uuid
)
SELECT clock_timestamp() AS checked_at,
  coalesce((SELECT jsonb_agg(to_jsonb(b)) FROM batches b),'[]'::jsonb) AS batches,
  coalesce((SELECT jsonb_agg(to_jsonb(r)) FROM results r),'[]'::jsonb) AS results,
  coalesce((SELECT jsonb_agg(to_jsonb(o) ORDER BY o.sequence) FROM operations o),'[]'::jsonb) AS operations,
  coalesce((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.operation_id,a.attempt_number) FROM attempts a),'[]'::jsonb) AS attempts,
  coalesce((SELECT jsonb_agg(to_jsonb(f)) FROM folders f),'[]'::jsonb) AS new_folders,
  coalesce((SELECT jsonb_agg(to_jsonb(o)) FROM orders o),'[]'::jsonb) AS new_orders;
