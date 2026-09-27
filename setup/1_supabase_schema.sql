-- =====================================================================
-- BIYU AI Agency — Automated Email Outreach
-- Supabase schema. Already applied to project imtmfmhqfuwxsrztgclb.
-- To rebuild elsewhere: Supabase → SQL Editor → paste → Run (safe to re-run).
--
-- n8n connects with the Postgres credential (postgres user) and calls the
-- functions below. The dashboard connects with the anon key + a logged-in
-- admin user and is limited by Row Level Security.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Settings (single row, edited from the dashboard)
-- ---------------------------------------------------------------------
create table if not exists public.outreach_settings (
  id               smallint primary key default 1 check (id = 1),
  target_industry  text    not null default 'Retail & Distribution',
  daily_limit      int     not null default 30 check (daily_limit between 0 and 150),
  max_followups    int     not null default 2  check (max_followups between 0 and 5),
  paused           boolean not null default true,   -- starts paused; switch to Live from the dashboard
  notify_email     text    not null default 'gabanaofentse1@gmail.com',
  sender_name      text    not null default 'Ofentse Gabana',
  sender_title     text    not null default 'Founding Growth Lead, BIYU AI Agency',
  sender_email     text    not null default '',     -- the mailbox n8n sends from (set this!)
  warmup_start     date    not null default (now() at time zone 'Africa/Gaborone')::date,
  window_start_hour int    not null default 8  check (window_start_hour between 0 and 23),
  window_end_hour   int    not null default 16 check (window_end_hour between 1 and 24),
  last_run_at      timestamptz,
  last_alert_at    timestamptz,
  updated_at       timestamptz not null default now()
);
insert into public.outreach_settings (id) values (1) on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 2. Industries + the pitch the AI uses for each
-- ---------------------------------------------------------------------
create table if not exists public.industries (
  name       text primary key,
  pitch      text not null,
  created_at timestamptz not null default now()
);
insert into public.industries (name, pitch) values
  ('Retail & Distribution',
   'BIYU AI Agency builds automations for retailers, wholesalers and distributors: capturing orders from WhatsApp and email, stock-level alerts, automatic invoices, instant replies to customer enquiries and daily sales reports, so the team spends less time on admin and fewer orders slip through the cracks.'),
  ('Clinics',
   'BIYU AI Agency builds a WhatsApp AI booking agent for private clinics: patients can book, reschedule and get reminders on WhatsApp at any hour, which takes pressure off the front desk and helps cut missed appointments.'),
  ('Dental (UAE)',
   'BIYU AI Agency builds a bilingual (English and Arabic) WhatsApp AI booking agent for dental clinics: patients book, reschedule and receive reminders on WhatsApp around the clock, freeing up reception and helping reduce no-shows.')
on conflict (name) do nothing;

-- ---------------------------------------------------------------------
-- 3. Prospects
-- ---------------------------------------------------------------------
create table if not exists public.prospects (
  id             uuid primary key default gen_random_uuid(),
  email          text not null unique check (email ~* '^[^@\s]+@[^@\s]+\.[a-z]{2,}$'),
  full_name      text,
  company        text,
  job_title      text,
  linkedin       text,
  industry       text not null,
  country        text default 'Botswana',
  notes          text,          -- optional personalisation hook, e.g. "just opened a 3rd branch"
  status         text not null default 'new'
                 check (status in ('new','contacted','replied','completed','opted_out','bounced','invalid')),
  followups_sent int  not null default 0,
  last_sent_at   timestamptz,
  thread_id      text,
  first_gmail_id text,
  rfc_message_id text,
  first_subject  text,
  fail_count     int  not null default 0,
  locked_until   timestamptz,
  replied_at     timestamptz,
  created_at     timestamptz not null default now()
);
create index if not exists prospects_industry_status_idx on public.prospects (industry, status);
create index if not exists prospects_thread_idx          on public.prospects (thread_id);
create index if not exists prospects_status_sent_idx     on public.prospects (status, last_sent_at);

-- Normalise emails and auto-create unknown industries on import
create or replace function public.prospects_before_write() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.email    := lower(btrim(new.email));
  new.industry := btrim(new.industry);
  insert into public.industries (name, pitch)
  values (new.industry,
          'BIYU AI Agency builds practical AI automations for African businesses: handling customer enquiries on WhatsApp and email, automating repetitive admin and producing clear daily reports, so teams can focus on growth.')
  on conflict (name) do nothing;
  return new;
end $$;
drop trigger if exists prospects_before_write on public.prospects;
create trigger prospects_before_write before insert or update of email, industry on public.prospects
for each row execute function public.prospects_before_write();

-- ---------------------------------------------------------------------
-- 4. Email log (every send, reply, bounce, opt-out, failure)
-- ---------------------------------------------------------------------
create table if not exists public.email_log (
  id          bigint generated always as identity primary key,
  prospect_id uuid references public.prospects(id) on delete cascade,
  direction   text not null check (direction in ('out','in')),
  kind        text not null check (kind in ('initial','followup','reply','opt_out','bounce','auto_reply','failed')),
  step        int,
  subject     text,
  body        text,
  gmail_id    text unique,
  thread_id   text,
  ai_fallback boolean not null default false,
  error       text,
  created_at  timestamptz not null default now()
);
create index if not exists email_log_created_idx  on public.email_log (created_at desc);
create index if not exists email_log_prospect_idx on public.email_log (prospect_id);

-- ---------------------------------------------------------------------
-- 5. Permanent do-not-contact list (survives deleting / re-importing prospects)
-- ---------------------------------------------------------------------
create table if not exists public.do_not_contact (
  email      text primary key,
  reason     text not null,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 6. Helpers
-- ---------------------------------------------------------------------
create or replace function public.outreach_today_start() returns timestamptz
language sql stable set search_path = public as $$
  select date_trunc('day', now() at time zone 'Africa/Gaborone') at time zone 'Africa/Gaborone'
$$;

-- Warm-up ramp: week 1 max 10/day, week 2 max 20, week 3 max 35, then your limit.
create or replace function public.outreach_effective_limit() returns int
language sql stable set search_path = public as $$
  select least(s.daily_limit,
           case when d < 7  then 10
                when d < 14 then 20
                when d < 21 then 35
                else 100000 end)
  from (select daily_limit,
               (now() at time zone 'Africa/Gaborone')::date - warmup_start as d
        from outreach_settings where id = 1) s
$$;

-- ---------------------------------------------------------------------
-- 7. SEND QUEUE — called by n8n every 15 min (weekdays).
--    Follow-ups due (3 days after last email) go first, then new prospects
--    in the target industry. Spreads sends randomly across the window and
--    never exceeds the (warm-up adjusted) daily limit.
--    p_test = true: ignores pause/window/limit, returns 1 row, locks nothing.
-- ---------------------------------------------------------------------
create or replace function public.get_send_queue(p_test boolean default false)
returns table (
  prospect_id uuid, email text, full_name text, first_name text, company text,
  job_title text, industry text, country text, notes text,
  kind text, step int, thread_id text, rfc_message_id text, first_subject text,
  pitch text, sender_name text, sender_title text, sender_email text,
  notify_email text, max_followups int, is_test boolean
)
language plpgsql set search_path = public as $$
#variable_conflict use_column
declare
  s            outreach_settings;
  v_local      timestamp := now() at time zone 'Africa/Gaborone';
  v_sent       int;
  v_remaining  int;
  v_ticks_left int;
  v_n          int;
begin
  select * into s from outreach_settings where id = 1 for update;

  -- Close sequences that got every follow-up and 3 more days of silence
  update prospects p set status = 'completed'
   where p.status = 'contacted'
     and p.followups_sent >= s.max_followups
     and p.last_sent_at <= now() - interval '3 days';

  if p_test then
    v_n := 1;
  else
    update outreach_settings set last_run_at = now() where id = 1;
    if s.paused then return; end if;
    if extract(isodow from v_local) > 5
       or extract(hour from v_local) <  s.window_start_hour
       or extract(hour from v_local) >= s.window_end_hour then
      return;
    end if;

    select count(*) into v_sent from email_log e
     where e.direction = 'out' and e.kind in ('initial','followup')
       and e.created_at >= outreach_today_start();
    v_remaining := outreach_effective_limit() - v_sent;
    if v_remaining <= 0 then return; end if;

    -- 15-minute ticks left in today's window (including this one)
    v_ticks_left := greatest(1, ceil(extract(epoch from
                      (date_trunc('day', v_local) + make_interval(hours => s.window_end_hour)) - v_local) / 900.0)::int);
    v_n := floor(v_remaining::numeric / v_ticks_left)::int
           + case when random() < (v_remaining % v_ticks_left)::numeric / v_ticks_left then 1 else 0 end;
    v_n := least(v_n, 5);
    if v_n <= 0 then return; end if;
  end if;

  return query
  with due as (
    select p.id as pid, 'followup'::text as k, p.followups_sent + 1 as st, 0 as prio, p.last_sent_at as ord
      from prospects p
     where p.status = 'contacted'
       and p.followups_sent < s.max_followups
       and p.last_sent_at <= now() - interval '3 days'
       and p.thread_id is not null
       and (p.locked_until is null or p.locked_until < now())
       and not exists (select 1 from do_not_contact d where d.email = p.email)
    union all
    select p.id, 'initial', 0, 1, p.created_at
      from prospects p
     where p.status = 'new'
       and p.industry = s.target_industry
       and (p.locked_until is null or p.locked_until < now())
       and not exists (select 1 from do_not_contact d where d.email = p.email)
  ),
  picked as (
    select * from due order by prio, ord limit v_n
  ),
  locked as (
    update prospects p
       set locked_until = case when p_test then p.locked_until else now() + interval '20 minutes' end
      from picked
     where p.id = picked.pid
    returning p.*, picked.k, picked.st, picked.prio, picked.ord
  )
  select l.id, l.email, l.full_name,
         coalesce(split_part(regexp_replace(btrim(coalesce(l.full_name,'')),
                  '^(dr|mr|mrs|ms|miss|prof|rev)\.?\s+', '', 'i'), ' ', 1), '') as first_name,
         l.company, l.job_title, l.industry, l.country, l.notes,
         l.k, l.st, l.thread_id, l.rfc_message_id, l.first_subject,
         coalesce(i.pitch, ''), s.sender_name, s.sender_title, s.sender_email,
         s.notify_email, s.max_followups, p_test
    from locked l
    left join industries i on i.name = l.industry
   order by l.prio, l.ord;
end $$;

-- ---------------------------------------------------------------------
-- 8. Record a successful send
-- ---------------------------------------------------------------------
create or replace function public.record_sent(p jsonb) returns boolean
language plpgsql set search_path = public as $$
declare
  v_id   uuid := (p->>'prospect_id')::uuid;
  v_kind text := p->>'kind';
  v_step int  := coalesce((p->>'step')::int, 0);
begin
  if coalesce((p->>'is_test')::boolean, false) then
    return false;                         -- test sends touch nothing
  end if;

  insert into email_log (prospect_id, direction, kind, step, subject, body, gmail_id, thread_id, ai_fallback)
  values (v_id, 'out', v_kind, v_step, p->>'subject', p->>'body',
          nullif(p->>'gmail_id',''), nullif(p->>'thread_id',''),
          coalesce((p->>'ai_fallback')::boolean, false))
  on conflict (gmail_id) do nothing;

  if v_kind = 'initial' then
    update prospects set status = 'contacted', followups_sent = 0, last_sent_at = now(),
           thread_id = nullif(p->>'thread_id',''), first_gmail_id = nullif(p->>'gmail_id',''),
           rfc_message_id = nullif(p->>'rfc_message_id',''), first_subject = p->>'subject',
           locked_until = null, fail_count = 0
     where id = v_id and status = 'new';
  else
    update prospects set followups_sent = greatest(followups_sent, v_step), last_sent_at = now(),
           locked_until = null, fail_count = 0
     where id = v_id;
  end if;
  return true;
end $$;

-- ---------------------------------------------------------------------
-- 9. Record a failed send. Auto-pauses after 3 failures in an hour and
--    returns a row (-> n8n emails you) when an alert is needed.
-- ---------------------------------------------------------------------
create or replace function public.record_failed(p jsonb)
returns table (notify_email text, alert_subject text, alert_body text)
language plpgsql set search_path = public as $$
declare
  v_id        uuid    := nullif(p->>'prospect_id','')::uuid;
  v_recipient boolean := coalesce((p->>'recipient_problem')::boolean, false);
  v_err       text    := left(coalesce(p->>'error','Unknown error'), 1000);
  v_recent    int;
  s           outreach_settings;
begin
  if coalesce((p->>'is_test')::boolean, false) then
    return query select st.notify_email, 'BIYU Outreach: test send failed', 'The test send failed: ' || v_err
                 from outreach_settings st where st.id = 1;
    return;
  end if;

  insert into email_log (prospect_id, direction, kind, step, subject, error)
  values (v_id, 'out', 'failed', nullif(p->>'step','')::int, p->>'subject',
          case when v_recipient then '[bad address] ' else '' end || v_err);

  -- A bad address fails twice -> prospect marked invalid. Other errors
  -- (Gmail limits, expired login) never burn the prospect.
  update prospects
     set fail_count   = fail_count + case when v_recipient then 1 else 0 end,
         status       = case when v_recipient and fail_count + 1 >= 2 then 'invalid' else status end,
         locked_until = now() + interval '1 hour'
   where id = v_id;

  select count(*) into v_recent from email_log
   where kind = 'failed' and error not like '[bad address]%'
     and created_at > now() - interval '1 hour';

  select * into s from outreach_settings where id = 1 for update;
  if v_recent >= 3 and not s.paused then
    update outreach_settings set paused = true, last_alert_at = now() where id = 1;
    return query select s.notify_email,
      'BIYU Outreach auto-paused: ' || v_recent || ' failed sends in the last hour',
      'Outreach has been paused automatically to protect your mailbox and prospect list.' || E'\n\n' ||
      'Latest error: ' || v_err || E'\n\n' ||
      'Common causes: Gmail sending limit reached, expired Gmail connection in n8n, or DNS/auth problems. ' ||
      'Fix the cause, then switch Outreach back to Live on the dashboard.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 10. Record an inbound email (reply / opt-out / bounce / auto-reply).
--     Returns a row only when you should be notified (real replies).
-- ---------------------------------------------------------------------
create or replace function public.record_inbound(p jsonb)
returns table (notify_email text, email text, full_name text, company text, industry text,
               step int, subject text, snippet text, thread_id text, sender_email text)
language plpgsql set search_path = public as $$
#variable_conflict use_column
declare
  v_p    prospects;
  v_kind text := coalesce(p->>'kind', 'reply');
begin
  if exists (select 1 from email_log e where e.gmail_id = p->>'gmail_id') then
    return;                                            -- already processed
  end if;

  select * into v_p from prospects pr where pr.thread_id = p->>'thread_id' limit 1;
  if not found and v_kind <> 'bounce' then
    select * into v_p from prospects pr where pr.email = lower(btrim(p->>'from_email')) limit 1;
  end if;
  if v_p.id is null then
    return;                                            -- not an outreach email
  end if;

  insert into email_log (prospect_id, direction, kind, step, subject, body, gmail_id, thread_id)
  values (v_p.id, 'in', v_kind, v_p.followups_sent, p->>'subject', p->>'body',
          p->>'gmail_id', p->>'thread_id')
  on conflict (gmail_id) do nothing;

  if v_kind = 'reply' then
    update prospects pr set status = case when pr.status in ('opted_out','bounced') then pr.status else 'replied' end,
           replied_at = coalesce(pr.replied_at, now()), locked_until = null
     where pr.id = v_p.id;
  elsif v_kind = 'opt_out' then
    update prospects pr set status = 'opted_out', locked_until = null where pr.id = v_p.id;
    insert into do_not_contact (email, reason) values (v_p.email, 'opted out') on conflict do nothing;
  elsif v_kind = 'bounce' then
    update prospects pr set status = 'bounced', locked_until = null where pr.id = v_p.id;
    insert into do_not_contact (email, reason) values (v_p.email, 'bounced') on conflict do nothing;
  end if;

  if v_kind = 'reply' then
    return query
    select st.notify_email, v_p.email, v_p.full_name, v_p.company, v_p.industry,
           v_p.followups_sent, p->>'subject', left(coalesce(p->>'snippet',''), 600),
           coalesce(p->>'thread_id', v_p.thread_id), st.sender_email
      from outreach_settings st where st.id = 1;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 11. Dashboard numbers in one call
-- ---------------------------------------------------------------------
create or replace function public.outreach_stats() returns jsonb
language sql stable set search_path = public as $$
  with s as (select * from outreach_settings where id = 1),
       t as (select outreach_today_start() as start)
  select jsonb_build_object(
    'sent_today',      (select count(*) from email_log, t where direction = 'out' and kind in ('initial','followup') and created_at >= t.start),
    'failed_today',    (select count(*) from email_log, t where kind = 'failed' and created_at >= t.start),
    'effective_limit', outreach_effective_limit(),
    'warmup_day',      (select (now() at time zone 'Africa/Gaborone')::date - warmup_start + 1 from s),
    'total_sent',      (select count(*) from email_log where direction = 'out' and kind in ('initial','followup')),
    'contacted',       (select count(*) from prospects where first_gmail_id is not null),
    'replied',         (select count(*) from prospects where replied_at is not null),
    'opted_out',       (select count(*) from prospects where status = 'opted_out'),
    'bounced',         (select count(*) from prospects where status = 'bounced'),
    'followups_due',   (select count(*) from prospects p, s where p.status = 'contacted'
                          and p.followups_sent < s.max_followups and p.last_sent_at <= now() - interval '3 days'),
    'ai_fallback_7d',  (select count(*) from email_log where ai_fallback and created_at > now() - interval '7 days'),
    'pipeline',        (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
                          from (select p.status, count(*) n from prospects p, s
                                 where p.industry = s.target_industry group by p.status) x),
    'last_run_at',     (select last_run_at from s)
  )
$$;

-- ---------------------------------------------------------------------
-- 12. Security: only emails in outreach_admins can use the dashboard
--     (change / add your login email here)
-- ---------------------------------------------------------------------
create table if not exists public.outreach_admins (email text primary key);
insert into public.outreach_admins (email) values ('gabanaofentse1@gmail.com'), ('info.biyu.ai@gmail.com') on conflict do nothing;

create schema if not exists private;
grant usage on schema private to authenticated;

create or replace function private.is_outreach_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.outreach_admins a
                  where a.email = lower(coalesce(auth.jwt() ->> 'email', '')))
$$;
revoke execute on function private.is_outreach_admin() from public, anon;
grant  execute on function private.is_outreach_admin() to authenticated;
drop function if exists public.is_outreach_admin();

alter table public.outreach_settings enable row level security;
alter table public.industries        enable row level security;
alter table public.prospects         enable row level security;
alter table public.email_log         enable row level security;
alter table public.do_not_contact    enable row level security;
alter table public.outreach_admins   enable row level security;

drop policy if exists admin_all on public.outreach_settings;
create policy admin_all on public.outreach_settings for all to authenticated
  using (private.is_outreach_admin()) with check (private.is_outreach_admin());
drop policy if exists admin_all on public.industries;
create policy admin_all on public.industries for all to authenticated
  using (private.is_outreach_admin()) with check (private.is_outreach_admin());
drop policy if exists admin_all on public.prospects;
create policy admin_all on public.prospects for all to authenticated
  using (private.is_outreach_admin()) with check (private.is_outreach_admin());
drop policy if exists admin_read on public.email_log;
create policy admin_read on public.email_log for select to authenticated
  using (private.is_outreach_admin());
drop policy if exists admin_all on public.do_not_contact;
create policy admin_all on public.do_not_contact for all to authenticated
  using (private.is_outreach_admin()) with check (private.is_outreach_admin());
drop policy if exists admin_read on public.outreach_admins;
create policy admin_read on public.outreach_admins for select to authenticated
  using (private.is_outreach_admin());

-- Explicit table grants (RLS above still limits rows to admins)
grant usage on schema public to authenticated;
grant select, insert, update, delete on public.outreach_settings, public.industries,
      public.prospects, public.do_not_contact to authenticated;
grant select on public.email_log, public.outreach_admins to authenticated;
revoke all on public.outreach_settings, public.industries, public.prospects,
       public.email_log, public.do_not_contact, public.outreach_admins from anon;

-- Worker functions are for n8n only (it connects as postgres)
revoke execute on function public.prospects_before_write()  from public, anon, authenticated;
revoke execute on function public.get_send_queue(boolean) from public, anon, authenticated;
revoke execute on function public.record_sent(jsonb)      from public, anon, authenticated;
revoke execute on function public.record_failed(jsonb)    from public, anon, authenticated;
revoke execute on function public.record_inbound(jsonb)   from public, anon, authenticated;
revoke execute on function public.outreach_stats()        from public, anon;
grant  execute on function public.outreach_stats()        to authenticated;
