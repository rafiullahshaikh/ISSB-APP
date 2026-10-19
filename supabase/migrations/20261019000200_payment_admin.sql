begin;
create function private.payment_admin(actor uuid) returns void
language plpgsql security invoker set search_path = '' as $$ begin
 perform private.api_assert_service();
 perform 1 from public.admin_users where user_id=actor and active for share;
 if not found or not private.is_active_admin(actor) then perform private.api_fail('ADMIN_REQUIRED');end if;
end $$;

create function public.qiyadat_admin_payments(p_actor uuid,p_filters jsonb default '{}',p_cursor jsonb default null,p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = '' as $$ declare rows jsonb; begin
 perform private.api_actor(p_actor);perform private.payment_admin(p_actor);
 perform private.api_fields(p_filters,array['status','payment_method','submitted_from','submitted_to','transaction_hash'],'{}');
 if p_limit is null or p_limit not between 1 and 100 then perform private.api_fail('VALIDATION_ERROR');end if;
 if p_filters?'status' then perform private.api_choice(p_filters,'status',array['pending','approved','rejected']);end if;
 if p_filters?'payment_method' then perform private.api_choice(p_filters,'payment_method',array['easypaisa','jazzcash','bank_transfer']);end if;
 if p_filters?'transaction_hash' and (p_filters->>'transaction_hash')!~'^[a-f0-9]{64}$' then perform private.api_fail('VALIDATION_ERROR');end if;
 if p_filters?'submitted_from' then perform private.api_timestamp(p_filters,'submitted_from');end if;
 if p_filters?'submitted_to' then perform private.api_timestamp(p_filters,'submitted_to');end if;
 if (p_filters->>'submitted_from')::timestamptz>(p_filters->>'submitted_to')::timestamptz then perform private.api_fail('VALIDATION_ERROR');end if;
 if p_cursor is not null then perform private.api_fields(p_cursor,array['at','id'],array['at','id']);perform private.api_timestamp(p_cursor,'at');end if;
 perform private.api_rate(p_actor,'payment_admin_list',clock_timestamp());
 select coalesce(jsonb_agg(item order by submitted_at desc,id desc),'[]'::jsonb) into rows from (
 select p.id,p.submitted_at,jsonb_build_object('id',p.id,'user',jsonb_build_object('id',p.user_id,'email',u.email,'display_name',pr.display_name),
 'offer',jsonb_build_object('code',p.offer_code,'currency',p.currency,'amount_minor',p.amount_minor,'access_days',p.access_days),
 'payment_method',p.payment_method,'ciphertext',p.transaction_id_ciphertext,'hash',p.transaction_id_hash,'status',p.status,'submitted_at',private.api_time(p.submitted_at)) item
 from public.payment_submissions p left join public.profiles pr on pr.id=p.user_id left join auth.users u on u.id=p.user_id
 where (not p_filters?'status' or p.status=(p_filters->>'status')::public.payment_status)
 and (not p_filters?'payment_method' or p.payment_method=(p_filters->>'payment_method')::public.payment_method)
 and (not p_filters?'submitted_from' or p.submitted_at>=(p_filters->>'submitted_from')::timestamptz)
 and (not p_filters?'submitted_to' or p.submitted_at<(p_filters->>'submitted_to')::timestamptz)
 and (not p_filters?'transaction_hash' or p.transaction_id_hash=p_filters->>'transaction_hash')
 and (p_cursor is null or (p.submitted_at,p.id)<((p_cursor->>'at')::timestamptz,(p_cursor->>'id')::uuid))
 order by p.submitted_at desc,p.id desc limit p_limit+1) page;
 return rows;
end $$;

create function public.qiyadat_payment_decide(p_actor uuid,p_payment_id uuid,p_operation text,p_body jsonb,p_request_id uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare payment public.payment_submissions; candidate uuid; at_time timestamptz; starts timestamptz; entitlement public.entitlements;
 note text; reason public.payment_rejection_code; message text;
begin
 perform private.api_assert_service();
 if not private.is_active_admin(p_actor) then perform private.api_fail('ADMIN_REQUIRED');end if;
 select user_id into candidate from public.payment_submissions where id=p_payment_id;
 if candidate is null then perform private.api_fail('NOT_FOUND');end if;
 -- Consistent profile order also covers admins reviewing each other's submissions.
 perform 1 from public.profiles where id in (candidate,p_actor) order by id for update;
 perform private.payment_admin(p_actor);
 if not exists(select 1 from public.profiles where id=candidate and access_disabled_at is null) then perform private.api_fail('NOT_FOUND');end if;
 if p_request_id is null or p_operation is null or p_operation not in ('approve','reject') then perform private.api_fail('VALIDATION_ERROR');end if;
 if p_operation='approve' then
  perform private.api_fields(p_body,array['verification_note'],array['verification_note']);
  note:=private.api_string(p_body,'verification_note',1,500);
 else
  perform private.api_fields(p_body,array['reason_code','message'],array['reason_code','message']);
  reason:=private.api_choice(p_body,'reason_code',array['TRANSACTION_NOT_FOUND','AMOUNT_MISMATCH','DUPLICATE_TRANSACTION','WRONG_RECIPIENT','OTHER'])::public.payment_rejection_code;
  message:=private.api_string(p_body,'message',1,500);
 end if;
 if coalesce(note,message) ~ '[[:cntrl:]<>]' or btrim(coalesce(note,message))='' then perform private.api_fail('VALIDATION_ERROR');end if;
 at_time:=clock_timestamp();perform private.api_rate(p_actor,'payment_decide',at_time);
 select * into payment from public.payment_submissions where id=p_payment_id for update;
 if payment.user_id is distinct from candidate then perform private.api_fail('NOT_FOUND');end if;
 if payment.status<>'pending' then perform private.api_fail('PAYMENT_ALREADY_DECIDED');end if;
 if p_operation='approve' then
  perform 1 from public.entitlements where user_id=candidate and type='founding_30d' order by id for update;
  select greatest(at_time,coalesce(max(expires_at),at_time)) into starts from public.entitlements
   where user_id=candidate and type='founding_30d' and status='active' and expires_at>at_time;
  insert into public.entitlements(user_id,type,starts_at,expires_at,payment_submission_id)
  values(candidate,'founding_30d',starts,starts+make_interval(days=>payment.access_days),payment.id) returning * into entitlement;
  update public.payment_submissions set status='approved',decided_at=at_time,decided_by=p_actor,verification_note=note where id=payment.id;
 else
  update public.payment_submissions set status='rejected',decided_at=at_time,decided_by=p_actor,rejection_reason_code=reason,rejection_message=message where id=payment.id;
 end if;
 insert into public.admin_audit_log(actor_id,subject_id,action,resource_id,reason_code,request_id,created_at)
 values(p_actor,candidate,case when p_operation='approve' then 'payment_approved'::public.audit_action else 'payment_rejected'::public.audit_action end,payment.id,reason,p_request_id,at_time);
 if p_operation='reject' then return jsonb_build_object('payment_id',payment.id,'status','rejected','decided_at',private.api_time(at_time),
  'rejection',jsonb_build_object('reason_code',reason,'message',message));end if;
 return jsonb_build_object('payment_id',payment.id,'status','approved','decided_at',private.api_time(at_time),'decided_by',p_actor,
  'entitlement',jsonb_build_object('id',entitlement.id,'type',entitlement.type,'starts_at',private.api_time(entitlement.starts_at),
  'expires_at',private.api_time(entitlement.expires_at),'status',entitlement.status));
end $$;
revoke all on function private.payment_admin(uuid) from public,anon,authenticated;
revoke all on function public.qiyadat_admin_payments(uuid,jsonb,jsonb,integer) from public,anon,authenticated;
revoke all on function public.qiyadat_payment_decide(uuid,uuid,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function private.payment_admin(uuid) to service_role;
grant execute on function public.qiyadat_admin_payments(uuid,jsonb,jsonb,integer) to service_role;
grant execute on function public.qiyadat_payment_decide(uuid,uuid,text,jsonb,uuid) to service_role;
commit;
