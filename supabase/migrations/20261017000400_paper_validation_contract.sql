begin;
-- Section 6.1 documents VALIDATION_ERROR for invalid preparation fields;
-- PAPER_UPLOAD_INCOMPLETE belongs to OCR page/file completeness checks.
do $$ declare definition text; before_text text; after_text text; occurrences integer; begin
 definition:=pg_get_functiondef('public.qiyadat_paper_prepare(uuid,uuid,jsonb)'::regprocedure);
 before_text:=$old$perform private.api_fail('PAPER_UPLOAD_INCOMPLETE');$old$;
 after_text:=$new$perform private.api_fail('VALIDATION_ERROR','files','Pages must be contiguous, ordered and match the allowed page count.');$new$;
 occurrences:=(length(definition)-length(replace(definition,before_text,'')))/length(before_text);
 if occurrences<>3 then raise exception 'Unexpected preparation validation definition';end if;
 execute replace(definition,before_text,after_text);
end $$;
notify pgrst,'reload schema';
commit;
