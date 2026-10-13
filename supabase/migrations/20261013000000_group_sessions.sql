-- Sessions de groupe : un chrono commun.
--
-- Un membre lance « une session ensemble » ; les autres la rejoignent. L'horloge
-- (marche, pauses, cycle Pomodoro) est commune : elle vit dans `clock` (JSON
-- de l'app, `GroupClock`) et chaque geste d'un participant la réécrit. Le cours
-- et l'exercice restent à chacun, sur son appareil : rien ici ne les porte.
-- À la fin, chaque appareil enregistre **son** temps (depuis son arrivée).

create table if not exists public.group_sessions (
  id         uuid primary key default gen_random_uuid(),
  group_id   uuid not null references public.study_groups(id) on delete cascade,
  host_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  clock      jsonb not null,
  updated_by uuid not null default auth.uid(),
  updated_at timestamptz not null default now(),
  ended_at   timestamptz
);

-- Une seule session en cours par groupe : deux « lancer » simultanés ne font
-- pas deux sessions (le second rejoint la première).
create unique index if not exists group_sessions_live
  on public.group_sessions (group_id) where ended_at is null;

create table if not exists public.group_session_members (
  session_id uuid not null references public.group_sessions(id) on delete cascade,
  group_id   uuid not null references public.study_groups(id) on delete cascade,
  user_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  joined_at  timestamptz not null default now(),
  left_at    timestamptz,
  primary key (session_id, user_id)
);

alter table public.group_sessions enable row level security;
alter table public.group_session_members enable row level security;

grant select, insert, update, delete on public.group_sessions, public.group_session_members to authenticated;

drop policy if exists group_sessions_read on public.group_sessions;
create policy group_sessions_read on public.group_sessions
  for select to authenticated using (public.is_group_member(group_id));

drop policy if exists group_sessions_insert on public.group_sessions;
create policy group_sessions_insert on public.group_sessions
  for insert to authenticated
  with check (public.is_group_member(group_id) and host_id = auth.uid() and updated_by = auth.uid());

-- Tout participant fait avancer l'horloge (pause, reprise, fin).
drop policy if exists group_sessions_update on public.group_sessions;
create policy group_sessions_update on public.group_sessions
  for update to authenticated
  using (public.is_group_member(group_id))
  with check (public.is_group_member(group_id) and updated_by = auth.uid());

drop policy if exists group_session_members_read on public.group_session_members;
create policy group_session_members_read on public.group_session_members
  for select to authenticated using (public.is_group_member(group_id));

drop policy if exists group_session_members_write on public.group_session_members;
create policy group_session_members_write on public.group_session_members
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and public.is_group_member(group_id));

-- Temps réel : une pause donnée par un membre arrive chez les autres à l'instant.
alter table public.group_sessions replica identity full;
alter table public.group_session_members replica identity full;

do $$
declare
  t text;
begin
  foreach t in array array['group_sessions', 'group_session_members'] loop
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
