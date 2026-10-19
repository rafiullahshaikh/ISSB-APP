begin;
-- Reject the exact submitted reference anywhere in a note/message, including
-- short or multiword references. No decryption or plaintext reference is needed.
create function private.payment_text_has_reference(value text,reference_hash text) returns boolean
language sql immutable strict security invoker set search_path = '' as $$
 select exists(select 1 from generate_series(1,char_length(value)) start_at
 cross join lateral generate_series(1,least(100,char_length(value)-start_at+1)) size
 where encode(extensions.digest(substring(normalize(value,NFC) from start_at for size),'sha256'),'hex')=reference_hash);
$$;
create function private.payment_private_text_guard() returns trigger
language plpgsql security invoker set search_path = '' as $$ begin
 if tg_op='UPDATE' and new.verification_note is not distinct from old.verification_note
 and new.rejection_message is not distinct from old.rejection_message then return new;end if;
 if private.payment_text_has_reference(new.verification_note,new.transaction_id_hash)
 or private.payment_text_has_reference(new.rejection_message,new.transaction_id_hash)
 then perform private.api_fail('VALIDATION_ERROR','body','Do not include the transaction reference in decision text.');end if;
 return new;
end $$;
create trigger payment_private_text before insert or update on public.payment_submissions
 for each row execute function private.payment_private_text_guard();
revoke all on function private.payment_text_has_reference(text,text) from public,anon,authenticated;
revoke all on function private.payment_private_text_guard() from public,anon,authenticated;
grant execute on function private.payment_text_has_reference(text,text),private.payment_private_text_guard() to service_role;
-- UPDATE/DELETE are already denied and trigger-guarded. Also close TRUNCATE.
revoke truncate on public.admin_audit_log from service_role;
commit;
