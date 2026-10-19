begin;
alter table public.payment_offers add column benefits jsonb;
alter table public.payment_offers add constraint payment_offer_benefits check (
 (benefits is null and not active) or (benefits is not null and benefits =
 '{"additional_20_word_sessions":true,"session_access":"during_entitlement","reports_per_rolling_window":3,"report_window_hours":24,"saved_history_and_progress":true}'::jsonb));
update public.app_settings set value=value||'{"payment_submit":5,"payment_admin_list":60,"payment_decide":60}'::jsonb where key='api_rate_limits';

create function public.qiyadat_payment_offers() returns jsonb
language plpgsql security invoker set search_path = '' as $$ begin
 perform private.api_assert_service();
 if not private.api_flag('payments_enabled') then perform private.api_fail('FEATURE_DISABLED'); end if;
 return coalesce((select jsonb_agg(jsonb_build_object('code',code,'name',name,'currency',currency,
 'amount_minor',amount_minor,'access_days',access_days,'benefits',benefits,'accepted_methods',accepted_methods,
 'instructions',instructions) order by code) from public.payment_offers
 where active and valid_from<=statement_timestamp() and (valid_until is null or valid_until>statement_timestamp())), '[]'::jsonb);
end $$;

create function public.qiyadat_payment_submit(p_actor uuid,p_body jsonb,p_key text,p_ciphertext bytea,p_hash text,p_masked text)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare k public.api_idempotency_keys; offer public.payment_offers; payment public.payment_submissions;
 at_time timestamptz; result jsonb; method public.payment_method; v_constraint text; failure text;
begin
 perform private.api_actor(p_actor);
 if not private.api_flag('payments_enabled') then perform private.api_fail('FEATURE_DISABLED'); end if;
 perform private.api_fields(p_body,array['offer_code','payment_method','transaction_hash'],array['offer_code','payment_method','transaction_hash']);
 perform private.api_string(p_body,'offer_code',1,80);
 method:=private.api_choice(p_body,'payment_method',array['easypaisa','jazzcash','bank_transfer'])::public.payment_method;
 if p_hash is null or p_hash!~'^[a-f0-9]{64}$' or p_body->>'transaction_hash' is distinct from p_hash
 or p_ciphertext is null or octet_length(p_ciphertext) not between 30 and 429 or get_byte(p_ciphertext,0)<>1
 or p_masked is null or p_masked!~'^\*{4,}.{1,4}$' then perform private.api_fail('VALIDATION_ERROR'); end if;
 k:=private.api_reserve_key(p_actor,'POST /payments',p_key,p_body);
 if k.response_body is not null then return jsonb_build_object('status',k.response_status,'body',k.response_body); end if;
 at_time:=clock_timestamp();
 perform private.api_rate(p_actor,'payment_submit',at_time);
 -- Business failures retain the rate hit but neither a resource nor an unfinished key.
 begin
  select * into offer from public.payment_offers where code=p_body->>'offer_code' for share;
  at_time:=clock_timestamp();
  if not found or not offer.active or offer.valid_from>at_time or (offer.valid_until is not null and offer.valid_until<=at_time)
   then perform private.api_fail('PAYMENT_OFFER_INACTIVE'); end if;
  if not method=any(offer.accepted_methods) then perform private.api_fail('VALIDATION_ERROR','payment_method','Method is not accepted by this offer.'); end if;
  if exists(select 1 from public.payment_submissions where user_id=p_actor and status='pending') then perform private.api_fail('PAYMENT_PENDING_EXISTS'); end if;
  insert into public.payment_submissions(user_id,offer_id,offer_code,currency,amount_minor,access_days,payment_method,
   transaction_id_ciphertext,transaction_id_hash,transaction_id_masked,submitted_at)
  values(p_actor,offer.id,offer.code,offer.currency,offer.amount_minor,offer.access_days,method,p_ciphertext,p_hash,p_masked,at_time) returning * into payment;
  result:=jsonb_build_object('status',201,'body',jsonb_build_object('data',jsonb_build_object('id',payment.id,'offer_code',payment.offer_code,
   'payment_method',payment.payment_method,'transaction_id_masked',payment.transaction_id_masked,'status',payment.status,
   'submitted_at',private.api_time(payment.submitted_at),'decision',null)));
  perform private.api_resolve_key(k.id,result);return result;
 exception when raise_exception then
  if sqlerrm not in ('PAYMENT_OFFER_INACTIVE','PAYMENT_PENDING_EXISTS','VALIDATION_ERROR') then raise; end if;
  failure:=sqlerrm;
 when unique_violation then
  get stacked diagnostics v_constraint=constraint_name;
  if v_constraint='payment_one_pending_per_user' then failure:='PAYMENT_PENDING_EXISTS';
  elsif v_constraint='payment_submissions_payment_method_transaction_id_hash_key' then failure:='TRANSACTION_ID_EXISTS';else raise;end if;
 end;
 delete from public.api_idempotency_keys where id=k.id;
 return jsonb_build_object('error_code',failure);
end $$;

create function public.qiyadat_payment_history(p_cursor jsonb default null,p_limit integer default 20)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare rows jsonb; begin
 if auth.uid() is null or not private.candidate_can_access(auth.uid()) then raise exception using errcode='P0001',message='AUTH_INVALID';end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception using errcode='P0001',message='VALIDATION_ERROR';end if;
 if p_cursor is not null and (jsonb_typeof(p_cursor) is distinct from 'object' or not p_cursor ?& array['at','id']
  or exists(select 1 from jsonb_object_keys(p_cursor) k where k not in ('at','id'))
  or jsonb_typeof(p_cursor->'at') is distinct from 'string' or jsonb_typeof(p_cursor->'id') is distinct from 'string'
  or p_cursor->>'at' !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$'
  or not isfinite((p_cursor->>'at')::timestamptz) or (p_cursor->>'id')::uuid is null)
 then raise exception using errcode='P0001',message='VALIDATION_ERROR';end if;
 select coalesce(jsonb_agg(item order by submitted_at desc,id desc),'[]'::jsonb) into rows from (
 select p.id,p.submitted_at,jsonb_build_object('id',p.id,'offer_code',p.offer_code,'payment_method',p.payment_method,
 'transaction_id_masked',p.transaction_id_masked,'status',p.status,'submitted_at',to_char(p.submitted_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),'decided_at',to_char(p.decided_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
 'rejection',case when p.status='rejected' then jsonb_build_object('reason_code',p.rejection_reason_code,'message',p.rejection_message) end,
 'entitlement',case when p.status='approved' and e.id is not null then jsonb_build_object('type',e.type,'starts_at',to_char(e.starts_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),'expires_at',to_char(e.expires_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')) end) item
 from public.payment_submissions p left join public.entitlements e on e.payment_submission_id=p.id and e.user_id=auth.uid()
 where p.user_id=auth.uid() and (p_cursor is null or (p.submitted_at,p.id)<((p_cursor->>'at')::timestamptz,(p_cursor->>'id')::uuid))
 order by p.submitted_at desc,p.id desc limit p_limit+1) page;
 return rows;
exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow then
 raise exception using errcode='P0001',message='VALIDATION_ERROR';
end $$;
revoke all on function public.qiyadat_payment_offers() from public,anon,authenticated;
revoke all on function public.qiyadat_payment_submit(uuid,jsonb,text,bytea,text,text) from public,anon,authenticated;
revoke all on function public.qiyadat_payment_history(jsonb,integer) from public,anon;
grant execute on function public.qiyadat_payment_offers() to service_role;
grant execute on function public.qiyadat_payment_submit(uuid,jsonb,text,bytea,text,text) to service_role;
grant execute on function public.qiyadat_payment_history(jsonb,integer) to authenticated;
commit;
