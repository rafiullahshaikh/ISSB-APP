-- API_SPEC.md 1.1.0: protected lifetime claim, exact replay and server helpers.
begin;
alter table public.wat_sessions add column is_free_demo boolean not null default false;
alter table public.wat_sessions add column technical_recovery_until timestamptz
  check (technical_recovery_until is null or (isfinite(technical_recovery_until) and technical_recovery_until > expires_at));
alter table public.wat_sessions add column technical_failure_verified_at timestamptz
  check (technical_failure_verified_at is null or isfinite(technical_failure_verified_at));
create unique index sessions_one_lifetime_free_demo on public.wat_sessions(user_id) where is_free_demo;
create index sessions_created_history_idx on public.wat_sessions(user_id, created_at desc, id desc);
alter table public.api_idempotency_keys add column response_body jsonb
  check (response_body is null or jsonb_typeof(response_body) = 'object');
-- Exact replay can include accepted answers on resume. This column remains service-only,
-- like the entire idempotency table; it never stores request headers or credentials.
alter table public.feedback_reports add column is_free_demo boolean not null default false;
create unique index reports_one_final_free_demo on public.feedback_reports(session_id) where is_free_demo;
create unique index entitlements_one_active_beta on public.entitlements(user_id)
  where type = 'beta' and status = 'active';

-- Preserve whitespace-only candidate wording instead of rewriting it to an empty string.
do $$ declare c record; begin
  for c in select conname from pg_catalog.pg_constraint
    where conrelid = 'public.wat_responses'::regclass and contype = 'c'
      and pg_catalog.pg_get_constraintdef(oid) like '%status%answered%'
  loop execute format('alter table public.wat_responses drop constraint %I', c.conname); end loop;
end $$;
alter table public.wat_responses add constraint response_text_status_consistent check (
  (status = 'answered' and answer ~ '[^[:space:]]' and completed)
  or (status = 'blank' and answer !~ '[^[:space:]]' and completed)
  or (status = 'not_attempted' and answer = '' and not completed));

create table private.api_rate_windows (
  user_id uuid not null references public.profiles(id) on delete cascade,
  operation text not null,
  window_start timestamptz not null check (isfinite(window_start)),
  hits integer not null check (hits > 0),
  primary key (user_id, operation, window_start)
);
alter table private.api_rate_windows enable row level security;
alter table private.api_rate_windows force row level security;
revoke all on private.api_rate_windows from public, anon, authenticated;
grant select, insert, update, delete on private.api_rate_windows to service_role;
create index api_rate_expiry_idx on private.api_rate_windows(window_start);

insert into public.app_settings(key, value) values
 ('wat_enabled', 'true'), ('FREE_DIAGNOSTIC_SESSIONS', '1'),
 ('api_rate_limits', '{"start":10,"answer":180,"finish":30,"import":30,"profile":60}')
on conflict (key) do nothing;

create function private.api_fail(code text, field_name text default null, field_message text default null)
returns void language plpgsql stable set search_path = '' as $$ begin
  raise exception using errcode = 'P0001', message = code,
    detail = case when field_name is null then '{}' else
      jsonb_build_object('fields', jsonb_build_object(field_name, coalesce(field_message, 'Invalid value.')))::text end;
end $$;
create function private.api_time(value timestamptz) returns text
language sql stable set search_path = '' as $$
 select case when value is null then null else
   to_char(value at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') end;
$$;
create function private.api_flag(name text) returns boolean
language sql stable set search_path = '' as $$
 select coalesce((select value = 'true'::jsonb from public.app_settings where key = name), false);
$$;
create function private.api_assert_service() returns void
language plpgsql volatile set search_path = '' as $$ begin
 if coalesce(auth.role(), '') <> 'service_role' then perform private.api_fail('FORBIDDEN'); end if;
end $$;
create function private.api_actor(actor uuid) returns void
language plpgsql set search_path = '' as $$ begin
 perform private.api_assert_service();
 perform 1 from public.profiles where id = actor and access_disabled_at is null for update;
 if not found then perform private.api_fail('AUTH_INVALID'); end if;
end $$;
create function private.api_fields(body jsonb, allowed text[], required text[]) returns void
language plpgsql stable set search_path = '' as $$ declare field text; begin
 if jsonb_typeof(body) is distinct from 'object' then perform private.api_fail('VALIDATION_ERROR','body','Must be an object.'); end if;
 for field in select jsonb_object_keys(body) loop
   if not field = any(allowed) then perform private.api_fail('VALIDATION_ERROR','body','Unknown properties are not allowed.'); end if;
 end loop;
 foreach field in array required loop
   if not body ? field or body->field = 'null'::jsonb then perform private.api_fail('VALIDATION_ERROR',field,'Required.'); end if;
 end loop;
end $$;
create function private.api_string(body jsonb, field text, minimum integer, maximum integer) returns text
language plpgsql stable set search_path = '' as $$ declare value text; begin
 value := body->>field;
 if jsonb_typeof(body->field) is distinct from 'string' or char_length(value) not between minimum and maximum
 then perform private.api_fail('VALIDATION_ERROR',field,'Invalid text length or type.'); end if;
 return value;
end $$;
create function private.api_integer(body jsonb, field text, minimum bigint, maximum bigint) returns bigint
language plpgsql stable set search_path = '' as $$ declare value numeric; begin
 if jsonb_typeof(body->field) is distinct from 'number' then perform private.api_fail('VALIDATION_ERROR',field,'Must be an integer.'); end if;
 value := (body->>field)::numeric;
 if value <> trunc(value) or value not between minimum and maximum then
   perform private.api_fail('VALIDATION_ERROR',field,'Integer out of range.'); end if;
 return value::bigint;
end $$;
create function private.api_timestamp(body jsonb, field text) returns timestamptz
language plpgsql stable set search_path = '' as $$ declare value text; parsed timestamptz; begin
 value := private.api_string(body,field,20,40);
 if value !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$' then
   perform private.api_fail('VALIDATION_ERROR',field,'Must be an RFC 3339 timestamp.'); end if;
 begin parsed := value::timestamptz;
 exception when invalid_datetime_format or datetime_field_overflow then
   perform private.api_fail('VALIDATION_ERROR',field,'Invalid timestamp.'); end;
 if not isfinite(parsed) then perform private.api_fail('VALIDATION_ERROR',field,'Invalid timestamp.'); end if;
 return parsed;
end $$;
create function private.api_choice(body jsonb, field text, choices text[]) returns text
language plpgsql stable set search_path = '' as $$ declare value text; begin
 value := private.api_string(body,field,1,128);
 if not value = any(choices) then perform private.api_fail('VALIDATION_ERROR',field,'Unsupported value.'); end if;
 return value;
end $$;
create function private.api_modes(body jsonb) returns void
language plpgsql stable set search_path = '' as $$ begin
 perform private.api_choice(body,'kind',array['diagnostic','practice']);
 perform private.api_choice(body,'practice_mode',array['training','simulation']);
 perform private.api_choice(body,'response_mode',array['typing','paper']);
end $$;
create function private.api_beta(actor uuid, at_time timestamptz) returns void
language plpgsql set search_path = '' as $$ begin
 if private.api_flag('beta_open') then
   insert into public.entitlements(user_id,type,starts_at) values(actor,'beta',at_time)
   on conflict (user_id) where type = 'beta' and status = 'active' do nothing;
 end if;
end $$;
create function private.api_has_access(actor uuid, at_time timestamptz) returns boolean
language sql stable set search_path = '' as $$
 select exists(select 1 from public.entitlements where user_id = actor and status = 'active'
   and starts_at <= at_time and (expires_at is null or expires_at > at_time)
   and (type = 'founding_30d' or (type = 'beta' and private.api_flag('beta_open'))));
$$;
create function private.api_rate(actor uuid, operation_name text, at_time timestamptz) returns void
language plpgsql set search_path = '' as $$ declare maximum integer; used integer; begin
 select (value->>operation_name)::integer into maximum from public.app_settings where key='api_rate_limits';
 if maximum is null or maximum < 1 then perform private.api_fail('FEATURE_DISABLED'); end if;
 insert into private.api_rate_windows(user_id,operation,window_start,hits)
 values(actor,operation_name,date_trunc('minute',at_time),1)
 on conflict(user_id,operation,window_start) do update set hits=private.api_rate_windows.hits+1
 returning hits into used;
 if used > maximum then perform private.api_fail('RATE_LIMITED'); end if;
end $$;
create function private.api_reserve_key(actor uuid, route_name text, key_value text, body jsonb)
returns public.api_idempotency_keys language plpgsql set search_path = '' as $$
declare record public.api_idempotency_keys; hash_value text; begin
 if key_value is null or char_length(key_value) not between 16 and 128 or key_value collate "C" !~ '^[ -~]+$'
 then perform private.api_fail('VALIDATION_ERROR','idempotency_key','Must be 16 to 128 printable ASCII characters.'); end if;
 hash_value := encode(extensions.digest(body::text,'sha256'),'hex');
 insert into public.api_idempotency_keys(user_id,route,idempotency_key,request_hash)
 values(actor,route_name,key_value,hash_value) on conflict(user_id,route,idempotency_key) do nothing;
 select * into record from public.api_idempotency_keys
 where user_id=actor and route=route_name and idempotency_key=key_value for update;
 if record.request_hash <> hash_value then perform private.api_fail('IDEMPOTENCY_CONFLICT'); end if;
 return record;
end $$;
create function private.api_resolve_key(key_id uuid, result jsonb) returns void
language sql set search_path = '' as $$
 update public.api_idempotency_keys set response_status=(result->>'status')::integer,
   response_body=result->'body', resource_id=(result#>>'{body,data,id}')::uuid where id=key_id;
$$;
create function private.api_rules() returns jsonb language sql immutable set search_path = '' as $$
 select jsonb_build_object('total_words',20,'seconds_per_word',15,'answer_grace_ms',2000,'answer_max_chars',280);
$$;
create function private.api_demo_guard() returns trigger language plpgsql set search_path = '' as $$ begin
 if new.is_free_demo and (new.source <> 'server' or new.kind <> 'diagnostic') then
   raise exception using errcode='23514',message='Free demo must be a server diagnostic'; end if;
 if tg_op='UPDATE' and new.is_free_demo is distinct from old.is_free_demo then
   raise exception using errcode='23514',message='Lifetime demo identity is immutable'; end if;
 return new;
end $$;
create trigger sessions_demo_guard before insert or update on public.wat_sessions
for each row execute function private.api_demo_guard();
create function private.api_report_demo_guard() returns trigger language plpgsql set search_path = '' as $$ begin
 select is_free_demo into new.is_free_demo from public.wat_sessions where id=new.session_id for update;
 return new;
end $$;
create trigger reports_demo_guard before insert or update on public.feedback_reports
for each row execute function private.api_report_demo_guard();

revoke all on all functions in schema private from public, anon;
-- Preserve the two existing RLS helper grants; all new API helpers are service-only.
do $$ declare f record; begin
 for f in select p.oid::regprocedure as signature from pg_catalog.pg_proc p
 join pg_catalog.pg_namespace n on n.oid=p.pronamespace
 where n.nspname='private' and p.proname like 'api_%' loop
   execute format('revoke all on function %s from authenticated',f.signature);
   execute format('grant execute on function %s to service_role',f.signature);
 end loop;
end $$;
commit;
