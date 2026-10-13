-- Synthetic local configuration only. No Auth identities, admins, or payment offers.
begin;

insert into public.wat_sets(id, code, version, kind)
values ('7dc73083-f0f1-46a4-ac65-7b7f42a6f9b1', 'diagnostic-v1', 1, 'diagnostic');

-- First 20 words of the existing HTML WORD_BANK, in its original order.
insert into public.wat_set_items(wat_set_id, version, position, word)
select '7dc73083-f0f1-46a4-ac65-7b7f42a6f9b1'::uuid, 1, ordinality::integer, word
from unnest(array[
  'Courage', 'Failure', 'Team', 'Risk', 'Duty',
  'Alone', 'Decision', 'Pressure', 'Honest', 'Future',
  'Lead', 'Problem', 'Change', 'Respect', 'Difficult',
  'Service', 'Mistake', 'Command', 'Hope', 'Success'
]) with ordinality as words(word, ordinality);

update public.wat_sets set published_at = now()
where id = '7dc73083-f0f1-46a4-ac65-7b7f42a6f9b1';

insert into public.app_settings(key, value) values
  ('ocr_enabled', 'false'), ('feedback_enabled', 'false'),
  ('payments_enabled', 'false'), ('beta_open', 'false'),
  ('API_VERSION', '1'), ('WAT_SCHEMA_VERSION', '1'),
  ('WAT_ALLOWED_SESSION_SIZES', '[20]'), ('WAT_SECONDS_PER_WORD', '15'),
  ('ANSWER_GRACE_MS', '2000'), ('ANSWER_MAX_CHARS', '280'),
  ('SESSION_WRITE_TTL_MINUTES', '30'), ('HISTORY_DEFAULT_LIMIT', '20'),
  ('HISTORY_MAX_LIMIT', '100'), ('PAPER_MAX_PAGES', '4'),
  ('PAPER_MAX_IMAGE_BYTES', '8388608'), ('PAPER_MAX_TOTAL_BYTES', '25165824'),
  ('PAPER_ALLOWED_MIME_TYPES', '["image/jpeg", "image/png", "image/webp"]'),
  ('SIGNED_UPLOAD_TTL_SECONDS', '900'), ('UNCONFIRMED_UPLOAD_TTL_HOURS', '24'),
  ('REPORTS_PER_ROLLING_WINDOW', '3'), ('REPORT_WINDOW_HOURS', '24'),
  ('FREE_DIAGNOSTIC_SESSIONS', '1'), ('FREE_DIAGNOSTIC_REPORTS', '1'), ('OCR_MONTHLY_APP_CAP', '900'),
  ('AI_PROVIDER_MAX_ATTEMPTS', '2'), ('OCR_PROVIDER_MAX_ATTEMPTS', '3'),
  ('PAYMENT_TRANSACTION_ID_MAX_CHARS', '100'), ('PAID_ACCESS_DAYS', '30'),
  ('RECENT_AUTH_MAX_AGE_MINUTES', '10'), ('EXPORT_DOWNLOAD_TTL_MINUTES', '10'),
  ('EXPORT_RETENTION_HOURS', '24'), ('ai_processing_terms_version', '"2026-10-01"')
on conflict (key) do update set value = excluded.value;

commit;
