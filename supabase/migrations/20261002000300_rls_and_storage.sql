begin;

-- Private helpers are not exposed as PostgREST RPCs (private is not an API schema).
create function private.candidate_can_access(owner_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select owner_id = (select auth.uid()) and exists (
    select 1 from public.profiles where id = (select auth.uid()) and access_disabled_at is null
  );
$$;

create function private.is_active_admin(actor_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.admin_users a join public.profiles p on p.id = a.user_id
    where a.user_id = actor_id and a.active and p.access_disabled_at is null);
$$;
revoke all on function private.is_active_admin(uuid) from public, anon, authenticated;
grant execute on function private.is_active_admin(uuid) to service_role;
revoke all on function private.candidate_can_access(uuid) from public, anon, authenticated;
grant usage on schema private to authenticated;
grant execute on function private.candidate_can_access(uuid) to authenticated;

-- Default deny even if Supabase's default public-schema grants would otherwise allow DML.
do $$
declare t text;
begin
  foreach t in array array['profiles', 'profile_consents', 'admin_users', 'entitlements',
    'payment_offers', 'payment_submissions', 'wat_sets', 'wat_set_items', 'wat_sessions',
    'wat_responses', 'paper_uploads', 'ocr_drafts', 'processing_jobs', 'feedback_reports',
    'feedback_items', 'usage_reservations', 'legacy_imports', 'data_exports',
    'deletion_requests', 'admin_audit_log', 'app_settings', 'api_idempotency_keys'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role', t);
    execute format('grant select, insert, update, delete on public.%I to service_role', t);
  end loop;
  foreach t in array array['profile_consents', 'entitlements', 'wat_sessions', 'wat_responses',
    'ocr_drafts', 'feedback_reports', 'feedback_items', 'legacy_imports', 'deletion_requests'] loop
    execute format('create policy candidate_read_own on public.%I for select to authenticated
      using ((select private.candidate_can_access(user_id)))', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end;
$$;

grant select (id, display_name, timezone, role, created_at, updated_at) on public.profiles to authenticated;
grant update (display_name, timezone) on public.profiles to authenticated;
create policy candidate_read_own on public.profiles for select to authenticated
  using ((select private.candidate_can_access(id)));
create policy candidate_update_safe_preferences on public.profiles for update to authenticated
  using ((select private.candidate_can_access(id)))
  with check ((select private.candidate_can_access(id)));

-- Column grants prevent bypassing masked API responses by querying protected data directly.
grant select (id, user_id, offer_code, currency, amount_minor, access_days, payment_method,
  transaction_id_masked, status, submitted_at, decided_at, rejection_reason_code,
  rejection_message, created_at, updated_at) on public.payment_submissions to authenticated;
create policy candidate_read_own on public.payment_submissions for select to authenticated
  using ((select private.candidate_can_access(user_id)));

grant select (id, user_id, session_id, type, status, attempt, error_code, created_at, updated_at,
  started_at, completed_at) on public.processing_jobs to authenticated;
create policy candidate_read_own on public.processing_jobs for select to authenticated
  using ((select private.candidate_can_access(user_id)));

grant select (id, user_id, session_id, page_number, status, upload_expires_at, expires_at,
  uploaded_at, confirmed_at, created_at, updated_at) on public.paper_uploads to authenticated;
create policy candidate_read_own on public.paper_uploads for select to authenticated
  using ((select private.candidate_can_access(user_id)) and status <> 'deleted');

grant select (id, user_id, status, format, ready_at, file_expires_at, created_at, updated_at)
  on public.data_exports to authenticated;
create policy candidate_read_own on public.data_exports for select to authenticated
  using ((select private.candidate_can_access(user_id)));

-- No browser policy/grant for admins, settings, counters, audit, idempotency,
-- offers or word-bank tables. Public configuration is served by the future API.
-- An allowlisted admin using a browser JWT retains the same candidate-only permissions.
revoke update, delete on public.admin_audit_log from service_role;
revoke update on public.profile_consents from service_role;

create function private.can_upload_paper_object(object_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.paper_uploads u
    join public.wat_sessions s on s.id = u.session_id and s.user_id = u.user_id
    join public.profiles p on p.id = u.user_id
    where u.object_path = object_name and u.user_id = (select auth.uid())
      and p.access_disabled_at is null and u.bucket_id = 'paper-uploads'
      and u.status = 'prepared' and u.upload_expires_at > statement_timestamp()
      and u.expires_at > statement_timestamp() and s.response_mode = 'paper'
      and s.status = 'awaiting_upload'
  );
$$;
revoke all on function private.can_upload_paper_object(text) from public, anon, authenticated;
grant execute on function private.can_upload_paper_object(text) to authenticated;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('paper-uploads', 'paper-uploads', false, 8388608,
  array['image/jpeg', 'image/png', 'image/webp']);

-- Supabase owns/enables RLS on storage.objects. Do not change ownership or disable RLS.
create policy qiyadat_paper_authorized_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'paper-uploads' and (select private.can_upload_paper_object(name)));
-- Restrictive guards also prevent future unrelated permissive policies opening this bucket.
create policy qiyadat_paper_insert_guard on storage.objects as restrictive for insert to authenticated
  with check (bucket_id <> 'paper-uploads' or (select private.can_upload_paper_object(name)));
create policy qiyadat_paper_anon_insert_guard on storage.objects as restrictive for insert to anon
  with check (bucket_id <> 'paper-uploads');
create policy qiyadat_paper_no_read on storage.objects as restrictive for select to anon, authenticated
  using (bucket_id <> 'paper-uploads');
create policy qiyadat_paper_no_update on storage.objects as restrictive for update to anon, authenticated
  using (bucket_id <> 'paper-uploads') with check (bucket_id <> 'paper-uploads');
create policy qiyadat_paper_no_delete on storage.objects as restrictive for delete to anon, authenticated
  using (bucket_id <> 'paper-uploads');

-- No read/list policy exists for this bucket, and candidates cannot create upload authorizations.
-- Future isolated service client issues upload-only authorization; no client upserts or downloads.
commit;
