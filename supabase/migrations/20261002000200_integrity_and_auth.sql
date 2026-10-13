begin;

create function private.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := statement_timestamp();
  return new;
end;
$$;

create function private.validate_profile() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = new.timezone
      and name not like 'posix/%' and name not like 'right/%' and name <> 'localtime') then
    raise exception using errcode = '23514', message = 'Invalid IANA timezone';
  end if;
  return new;
end;
$$;
create trigger profiles_validate before insert or update on public.profiles
for each row execute function private.validate_profile();

create function private.handle_new_auth_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- Never copy role, access, consent, or other editable Auth metadata.
  insert into public.profiles(id, role) values (new.id, 'candidate');
  return new;
end;
$$;
create trigger qiyadat_auth_user_created after insert on auth.users
for each row execute function private.handle_new_auth_user();
-- Handles identities that already exist when migrating a local database.
insert into public.profiles(id, role)
select id, 'candidate' from auth.users on conflict (id) do nothing;

create function private.reject_immutable_change() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception using errcode = '23514', message = 'Immutable record cannot be changed';
end;
$$;
create trigger audit_immutable before update or delete on public.admin_audit_log
for each row execute function private.reject_immutable_change();

create function private.protect_wat_set() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op <> 'INSERT' and old.published_at is not null then
    raise exception using errcode = '23514', message = 'Published WAT version is immutable';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if new.published_at is not null then
    if new.published_at < new.created_at or
       (select count(*) from public.wat_set_items where wat_set_id = new.id and version = new.version) <> 20 then
      raise exception using errcode = '23514', message = 'Publishing requires exactly 20 ordered words';
    end if;
  end if;
  return new;
end;
$$;
create trigger wat_sets_immutable before insert or update or delete on public.wat_sets
for each row execute function private.protect_wat_set();

create function private.protect_wat_set_item() returns trigger
language plpgsql security definer set search_path = '' as $$
declare parent_id uuid; parent_version integer; published timestamptz;
begin
  if tg_op = 'UPDATE' and (new.wat_set_id, new.version) is distinct from (old.wat_set_id, old.version) then
    raise exception using errcode = '23514', message = 'Set item identity cannot be moved';
  end if;
  if tg_op = 'DELETE' then
    parent_id := old.wat_set_id; parent_version := old.version;
  else
    parent_id := new.wat_set_id; parent_version := new.version;
  end if;
  -- Serializes item edits against publication to prevent a concurrent publication race.
  select published_at into published from public.wat_sets
  where id = parent_id and version = parent_version for update;
  if published is not null then
    raise exception using errcode = '23514', message = 'Published WAT words are immutable';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
create trigger wat_items_immutable before insert or update or delete on public.wat_set_items
for each row execute function private.protect_wat_set_item();

create function private.validate_session() returns trigger
language plpgsql security definer set search_path = '' as $$
declare allowed boolean;
begin
  if tg_op = 'INSERT' then
    if not exists (select 1 from public.wat_sets where id = new.wat_set_id
        and version = new.set_version and kind = new.kind and published_at is not null) then
      raise exception using errcode = '23514', message = 'Session requires a published WAT version';
    end if;
    if (new.source = 'server' and new.status <> 'in_progress') or
       (new.source <> 'server' and new.status <> 'finished') then
      raise exception using errcode = '23514', message = 'Invalid initial session state';
    end if;
  else
    if (new.id, new.user_id, new.client_session_id, new.wat_set_id, new.set_version, new.kind,
        new.practice_mode, new.response_mode, new.source, new.timing_trust, new.started_at,
        new.expires_at, new.imported_at, new.created_at)
      is distinct from
       (old.id, old.user_id, old.client_session_id, old.wat_set_id, old.set_version, old.kind,
        old.practice_mode, old.response_mode, old.source, old.timing_trust, old.started_at,
        old.expires_at, old.imported_at, old.created_at) then
      raise exception using errcode = '23514', message = 'Session identity and timing are immutable';
    end if;
    if old.finished_at is not null and new.finished_at is distinct from old.finished_at then
      raise exception using errcode = '23514', message = 'Canonical finish time is immutable';
    end if;
    if new.ocr_revision < old.ocr_revision then
      raise exception using errcode = '23514', message = 'OCR revision cannot decrease';
    end if;
    if new.status is distinct from old.status then
      allowed := case old.status
        when 'in_progress' then
          (new.response_mode = 'typing' and new.status = 'finished') or
          (new.response_mode = 'paper' and new.status = 'awaiting_upload')
        when 'awaiting_upload' then new.status = 'ocr_queued'
        when 'ocr_queued' then new.status = 'ocr_processing'
        when 'ocr_processing' then new.status in ('awaiting_confirmation', 'ocr_queued', 'failed')
        when 'awaiting_confirmation' then new.status = 'finished'
        when 'finished' then new.status = 'feedback_queued'
        when 'feedback_queued' then new.status = 'feedback_processing'
        when 'feedback_processing' then new.status in ('ready', 'feedback_queued', 'failed')
        else false
      end;
      if not allowed then
        raise exception using errcode = '23514', message = 'Invalid session state transition';
      end if;
    end if;
  end if;
  return new;
end;
$$;
create trigger sessions_validate before insert or update on public.wat_sessions
for each row execute function private.validate_session();

create function private.validate_response() returns trigger
language plpgsql security definer set search_path = '' as $$
declare s public.wat_sessions; expected_word text;
begin
  select * into s from public.wat_sessions where id = new.session_id for update;
  if not found then raise exception using errcode = '23503', message = 'Session not found'; end if;
  if tg_op = 'UPDATE' and (new.id, new.session_id, new.user_id, new.position, new.word, new.source, new.created_at)
    is distinct from (old.id, old.session_id, old.user_id, old.position, old.word, old.source, old.created_at) then
    raise exception using errcode = '23514', message = 'Response identity is immutable';
  end if;
  if tg_op = 'UPDATE' and old.locked and new is distinct from old then
    raise exception using errcode = '23514', message = 'Locked answer cannot be changed';
  end if;
  new.answer := normalize(replace(replace(new.answer, E'\r\n', E'\n'), E'\r', E'\n'), NFC);
  select word into expected_word from public.wat_set_items
    where wat_set_id = s.wat_set_id and version = s.set_version and position = new.position;
  if new.word is distinct from expected_word then
    raise exception using errcode = '23514', message = 'Response word must match the immutable set';
  end if;
  if (s.response_mode = 'paper' and new.source <> 'ocr_confirmed') or
     (s.response_mode = 'typing' and new.source = 'ocr_confirmed') or
     (s.source = 'legacy_local_storage' and s.response_mode = 'typing' and new.source <> 'legacy_typed') then
    raise exception using errcode = '23514', message = 'Invalid response source';
  end if;
  -- Actual answer acceptance/deadline checks belong in later authenticated transaction RPCs.
  return new;
end;
$$;
create trigger responses_validate before insert or update on public.wat_responses
for each row execute function private.validate_response();

create function private.validate_paper_upload() returns trigger
language plpgsql security definer set search_path = '' as $$
declare s public.wat_sessions; total_bytes bigint;
begin
  select * into s from public.wat_sessions where id = new.session_id for update;
  if not found then raise exception using errcode = '23503', message = 'Session not found'; end if;
  if tg_op = 'INSERT' and (s.response_mode <> 'paper' or s.status <> 'awaiting_upload') then
    raise exception using errcode = '23514', message = 'Uploads require a finished paper session';
  end if;
  if tg_op = 'UPDATE' and (new.id, new.user_id, new.session_id, new.page_number, new.bucket_id,
      new.object_path, new.content_type, new.size_bytes, new.sha256, new.created_at,
      new.upload_expires_at, new.expires_at)
    is distinct from (old.id, old.user_id, old.session_id, old.page_number, old.bucket_id,
      old.object_path, old.content_type, old.size_bytes, old.sha256, old.created_at,
      old.upload_expires_at, old.expires_at) then
    raise exception using errcode = '23514', message = 'Upload authorization is immutable';
  end if;
  select coalesce(sum(size_bytes), 0) into total_bytes from public.paper_uploads
    where session_id = new.session_id and id <> new.id and status <> 'deleted';
  if new.status <> 'deleted' and total_bytes + new.size_bytes > 25165824 then
    raise exception using errcode = '23514', message = 'Paper session exceeds total upload size';
  end if;
  return new;
end;
$$;
create trigger uploads_validate before insert or update on public.paper_uploads
for each row execute function private.validate_paper_upload();

create function private.validate_payment_decision() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    if (new.id, new.offer_id, new.offer_code, new.currency, new.amount_minor, new.access_days,
        new.payment_method, new.transaction_id_ciphertext, new.transaction_id_hash,
        new.transaction_id_masked, new.submitted_at, new.created_at)
      is distinct from (old.id, old.offer_id, old.offer_code, old.currency, old.amount_minor,
        old.access_days, old.payment_method, old.transaction_id_ciphertext,
        old.transaction_id_hash, old.transaction_id_masked, old.submitted_at, old.created_at) then
      raise exception using errcode = '23514', message = 'Payment reference and offer snapshot are immutable';
    end if;
    if new.user_id is distinct from old.user_id and new.user_id is not null then
      raise exception using errcode = '23514', message = 'Payment ownership cannot be reassigned';
    end if;
    if old.status <> 'pending' and (new.status, new.decided_at, new.decided_by,
        new.verification_note, new.rejection_reason_code, new.rejection_message)
      is distinct from (old.status, old.decided_at, old.decided_by, old.verification_note,
        old.rejection_reason_code, old.rejection_message) then
      raise exception using errcode = '23514', message = 'Payment decision is immutable';
    end if;
  end if;
  if new.status <> 'pending' and (tg_op = 'INSERT' or old.status = 'pending') then
    if not exists (select 1 from public.admin_users a join public.profiles p on p.id = a.user_id
      where a.user_id = new.decided_by and a.active and p.access_disabled_at is null) then
      raise exception using errcode = '23514', message = 'Payment decision requires an active allowlisted admin';
    end if;
  end if;
  return new;
end;
$$;
create trigger payments_validate before insert or update on public.payment_submissions
for each row execute function private.validate_payment_decision();

create function private.revoke_deleted_account_access() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.user_id is not null then
    update public.profiles set access_disabled_at = coalesce(access_disabled_at, new.requested_at)
      where id = new.user_id;
  end if;
  return new;
end;
$$;
create trigger deletion_revoke_access after insert on public.deletion_requests
for each row execute function private.revoke_deleted_account_access();

-- Reject non-finite creation/update dates on every application table.
do $$
declare t text;
begin
  foreach t in array array['profiles', 'profile_consents', 'admin_users', 'entitlements',
    'payment_offers', 'payment_submissions', 'wat_sets', 'wat_set_items', 'wat_sessions',
    'wat_responses', 'paper_uploads', 'ocr_drafts', 'processing_jobs', 'feedback_reports',
    'feedback_items', 'usage_reservations', 'legacy_imports', 'data_exports',
    'deletion_requests', 'admin_audit_log', 'app_settings', 'api_idempotency_keys'] loop
    execute format('alter table public.%I add constraint %I check (isfinite(created_at))',
      t, t || '_created_at_finite');
    if exists (select 1 from information_schema.columns
      where table_schema = 'public' and table_name = t and column_name = 'updated_at') then
      execute format('alter table public.%I add constraint %I
        check (isfinite(updated_at) and updated_at >= created_at)', t, t || '_updated_at_valid');
    end if;
  end loop;
end;
$$;

create function private.payment_transaction_hash(method public.payment_method, reference text) returns text
language plpgsql immutable strict set search_path = '' as $$
declare normalized text;
begin
  normalized := normalize(regexp_replace(reference, '^\s+|\s+$', '', 'g'), NFC);
  if char_length(normalized) not between 1 and 100 then
    raise exception using errcode = '23514', message = 'Invalid normalized transaction reference length';
  end if;
  -- method is reserved for provider-specific rules; uniqueness is enforced on (payment_method, hash). Lint 'unused parameter' is accepted.
  -- Provider separator rules are not specified; never remove unapproved separators or change case.
  return encode(extensions.digest(normalized, 'sha256'), 'hex');
end;
$$;

-- All mutable application tables carry server-maintained updated_at timestamps.
do $$
declare t text;
begin
  foreach t in array array['profiles', 'admin_users', 'payment_offers', 'payment_submissions',
    'entitlements', 'wat_sets', 'wat_set_items', 'wat_sessions', 'wat_responses', 'paper_uploads',
    'ocr_drafts', 'processing_jobs', 'usage_reservations', 'data_exports', 'deletion_requests',
    'app_settings', 'api_idempotency_keys'] loop
    execute format('create trigger zz_touch_updated_at before update on public.%I
      for each row execute function private.touch_updated_at()', t);
  end loop;
end;
$$;

revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.payment_transaction_hash(public.payment_method, text) to service_role;

commit;
