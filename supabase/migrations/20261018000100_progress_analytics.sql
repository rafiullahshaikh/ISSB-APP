begin;
create function private.progress_clock() returns timestamptz
language sql stable security invoker set search_path = '' as $$ select statement_timestamp(); $$;
revoke all on function private.progress_clock() from public,anon;
grant execute on function private.progress_clock() to authenticated;

create function public.qiyadat_progress(p_range text default '30d',p_compare text default 'previous_period',
 p_practice_mode text default 'all',p_response_mode text default 'all') returns jsonb
language plpgsql stable security invoker set search_path = '' as $$
declare actor uuid:=auth.uid(); zone text; at_time timestamptz:=private.progress_clock(); today date;
 from_at timestamptz; to_at timestamptz; week_at timestamptz; previous_at timestamptz; result jsonb; begin
 if actor is null or not private.candidate_can_access(actor) then
  raise exception using errcode='P0001',message='AUTH_INVALID';end if;
 if p_range is null or p_range not in ('7d','30d','90d','all') or p_compare is null or p_compare not in ('none','previous_period')
  or p_practice_mode is null or p_practice_mode not in ('all','training','simulation')
  or p_response_mode is null or p_response_mode not in ('all','typing','paper') then
  raise exception using errcode='P0001',message='VALIDATION_ERROR';end if;
 select timezone into zone from public.profiles where id=actor;
 today:=(at_time at time zone zone)::date;
 to_at:=(today+1)::timestamp at time zone zone;
 week_at:=(today-6)::timestamp at time zone zone;
 previous_at:=(today-13)::timestamp at time zone zone;
 from_at:=(today-case p_range when '7d' then 6 when '30d' then 29 when '90d' then 89 else 0 end)::timestamp at time zone zone;

 with sessions as materialized (
  select s.id,s.started_at,(s.started_at at time zone zone)::date as local_day,s.session_size,
   s.finished_at is not null and s.status not in ('in_progress','failed') as completed,
   s.practice_mode,s.timing_trust
  from public.wat_sessions s where s.user_id=actor and s.started_at<to_at
   and (p_practice_mode='all' or s.practice_mode::text=p_practice_mode)
   and (p_response_mode='all' or s.response_mode::text=p_response_mode)
 ), bounds as (
  select case when p_range='all' then coalesce(min(started_at),from_at) else from_at end as lower_at from sessions
 ), responses as (
  select r.session_id,count(*) filter(where r.completed) as completed_words,
   count(*) filter(where r.status='answered') as answered_words,
   sum(r.time_used_ms) filter(where r.completed and (s.practice_mode<>'simulation' or s.timing_trust='server_verified')) as total_ms,
   count(r.time_used_ms) filter(where r.completed and (s.practice_mode<>'simulation' or s.timing_trust='server_verified')) as timed_words
  from public.wat_responses r join sessions s on s.id=r.session_id where r.user_id=actor group by r.session_id
 ), reports as materialized (
  select distinct on (f.session_id) f.session_id,f.id,f.generated_at,f.overall_score,f.summary
  from public.feedback_reports f join sessions s on s.id=f.session_id
   join public.processing_jobs j on j.id=f.job_id and j.user_id=actor and j.session_id=s.id
  where f.user_id=actor and f.status='ready' and j.type='feedback' and j.status='succeeded'
  order by f.session_id,f.generated_at desc,f.id desc
 ), activity as materialized (
  select s.*,coalesce(r.completed_words,0) as completed_words,coalesce(r.answered_words,0) as answered_words,
   r.total_ms,coalesce(r.timed_words,0) as timed_words,f.id as report_id,f.overall_score
  from sessions s left join responses r on r.session_id=s.id left join reports f on f.session_id=s.id
 ), selected as materialized (
  select a.* from activity a cross join bounds b where a.started_at>=b.lower_at
 ), totals as (
  select count(*) as sessions,count(*) filter(where completed) as completed_sessions,
   coalesce(sum(session_size),0) as words,coalesce(sum(completed_words),0) as completed_words,
   coalesce(sum(answered_words),0) as answers,count(report_id) as reports,
   round(sum(total_ms)/nullif(sum(timed_words),0)/1000.0,1) as average_time,
   round(avg(overall_score),1) as average_score from selected
 ), practice_dates as (
  select distinct local_day from sessions where completed
 ), streak as (
  select count(*) as days from (
   select local_day,row_number() over(order by local_day desc) as n,max(local_day) over() as anchor from practice_dates
  ) d where anchor>=today-1 and local_day=anchor-(n-1)::integer
 ), weeks as (
  select w.name,count(a.id) as sessions,round(avg(a.overall_score),1) as average_score,
   coalesce(round(sum(a.completed_words)*100.0/nullif(sum(a.session_size),0),1),0.0) as completion_percent
  from (values('current',week_at,to_at),('previous',previous_at,week_at)) w(name,lower_at,upper_at)
  left join activity a on a.started_at>=w.lower_at and a.started_at<w.upper_at
  where p_compare='previous_period' group by w.name
 ), weak_entries as materialized (
  select distinct on (f.id,e.value->>'code') f.id as report_id,f.generated_at,s.started_at,e.ordinality,
   e.value->>'code' as code,e.value->>'label' as label,f.summary#>>'{next_drill,code}' as drill
  from reports f join sessions s on s.id=f.session_id
  cross join lateral jsonb_array_elements(case when jsonb_typeof(f.summary->'weak_areas')='array'
   then f.summary->'weak_areas' else '[]'::jsonb end) with ordinality e(value,ordinality)
  where jsonb_typeof(e.value)='object' and e.value->>'code' in ('LOW_SPECIFICITY','LOW_CLARITY','LOW_AGENCY','LOW_REALISM','NEGATIVE_FRAMING')
   and jsonb_typeof(e.value->'label')='string' and char_length(e.value->>'label') between 1 and 160
   and f.summary#>>'{next_drill,code}' in ('ACTOR_ACTION_DRILL','CLARITY_DRILL','PRACTICAL_RESPONSE_DRILL')
  order by f.id,e.value->>'code',e.ordinality
 ), weak_counts as (
  select e.code,count(*) as reports from weak_entries e cross join bounds b where e.started_at>=b.lower_at group by e.code having count(*)>=2
 ), weak_latest as (
  select distinct on (e.code) e.code,e.label,e.drill from weak_entries e join weak_counts c on c.code=e.code
   cross join bounds b where e.started_at>=b.lower_at order by e.code,e.generated_at desc,e.report_id desc,e.ordinality
 ), weak_windows as (
  select e.code,count(*) filter(where e.started_at>=week_at) as current_count,
   count(*) filter(where e.started_at>=previous_at and e.started_at<week_at) as previous_count
  from weak_entries e group by e.code
 ), report_windows as (
  select count(*) filter(where a.started_at>=week_at) as current_count,
   count(*) filter(where a.started_at>=previous_at and a.started_at<week_at) as previous_count
  from activity a where a.report_id is not null
 )
 select jsonb_build_object(
  'range',jsonb_build_object('key',p_range,'from',to_char(b.lower_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
   'to',to_char(to_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),'timezone',zone),
  'totals',jsonb_build_object('sessions',t.sessions,'completed_sessions',t.completed_sessions,'words_presented',t.words,'answers_recorded',t.answers,'reports',t.reports),
  'metrics',jsonb_build_object('completion_percent',coalesce(round(t.completed_words*100.0/nullif(t.words,0),1),0.0),
   'average_response_seconds',t.average_time,'average_report_score',t.average_score,'current_streak_days',streak.days),
  'weekly_comparison',case when p_compare='previous_period' then (select jsonb_build_object(
   'current',jsonb_build_object('sessions',c.sessions,'average_score',c.average_score,'completion_percent',c.completion_percent),
   'previous',jsonb_build_object('sessions',p.sessions,'average_score',p.average_score,'completion_percent',p.completion_percent),
   'changes',jsonb_build_object('average_score',round(c.average_score-p.average_score,1),
    'completion_percentage_points',round(c.completion_percent-p.completion_percent,1))) from weeks c cross join weeks p where c.name='current' and p.name='previous') else null end,
  'trends',coalesce((select jsonb_agg(jsonb_build_object('session_id',id,'date',to_char(local_day,'YYYY-MM-DD'),
   'completion_percent',round(completed_words*100.0/session_size,1),'average_response_seconds',round(total_ms::numeric/nullif(timed_words,0)/1000.0,1),
   'report_score',overall_score) order by local_day,started_at,id) from selected where completed),'[]'::jsonb),
  'weak_areas',coalesce((select jsonb_agg(jsonb_build_object('code',c.code,'label',l.label,'report_count',c.reports,'recommended_drill',l.drill,
   'recent_direction',case when rw.current_count=0 or rw.previous_count=0 then 'stable'
    when w.current_count::numeric/rw.current_count<w.previous_count::numeric/rw.previous_count then 'improving'
    when w.current_count::numeric/rw.current_count>w.previous_count::numeric/rw.previous_count then 'declining' else 'stable' end)
   order by c.reports desc,c.code) from weak_counts c join weak_latest l on l.code=c.code join weak_windows w on w.code=c.code cross join report_windows rw),'[]'::jsonb),
  'generated_at',to_char(at_time at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')) into result
 from totals t cross join bounds b cross join streak;
 return result;
end $$;
revoke all on function public.qiyadat_progress(text,text,text,text) from public,anon;
grant execute on function public.qiyadat_progress(text,text,text,text) to authenticated;
notify pgrst,'reload schema';
commit;
