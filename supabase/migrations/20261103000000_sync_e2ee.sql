-- Généré par windows/scripts/gen-schema.ts depuis src/models/schema.ts — ne pas modifier à la main.
--
-- Synchronisation chiffrée de bout en bout (docs/sync-e2ee.md).
--
-- Les tables `sync_*` de 20261030000000_user_data_sync.sql portaient les champs en
-- colonnes, lisibles par le serveur. Elles étaient vides (la synchronisation n'avait
-- jamais été activée) : on les recrée avec une seule colonne de contenu, `payload`,
-- chiffrée par l'appareil (AES-256-GCM, la clé du compte ne quitte pas les appareils).
--
--   updated_at         heure de la modification, posée par l'appareil (la plus récente gagne) ;
--   deleted_at         pierre tombale (alors `payload` est nul) ;
--   server_updated_at  posée ici : le curseur des lectures ;
--   payload            nonce ‖ chiffré ‖ étiquette ; les champs du modèle y sont ;
--   key_id             identifiant public de la clé (16 octets en hexadécimal).
--
-- Le serveur voit donc encore QUAND une ligne change et COMBIEN il y en a ; il ne voit
-- ni leur contenu ni les relations entre elles.

-- `sync_vault` : un coffre par compte. Il dit qu'une clé existe et laquelle (`key_id`),
-- pour qu'un nouvel appareil sache à quoi s'attendre et vérifie la clé reçue. Il ne contient
-- aucun secret. Écrit une fois : pas de mise à jour, on le supprime pour le réinitialiser.
create table if not exists public.sync_vault (
  user_id    uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  key_id     text not null check (key_id ~ '^[0-9a-f]{32}$'),
  created_at timestamptz not null default now()
);

alter table public.sync_vault enable row level security;

drop policy if exists sync_vault_select on public.sync_vault;
create policy sync_vault_select on public.sync_vault for select using (user_id = auth.uid());
drop policy if exists sync_vault_insert on public.sync_vault;
create policy sync_vault_insert on public.sync_vault for insert with check (user_id = auth.uid());
drop policy if exists sync_vault_delete on public.sync_vault;
create policy sync_vault_delete on public.sync_vault for delete using (user_id = auth.uid());

create or replace function public.sync_vault_immutable()
returns trigger
language plpgsql
as $$
begin
  raise exception 'le coffre ne se modifie pas : on le supprime pour le réinitialiser' using errcode = '42501';
end;
$$;

drop trigger if exists sync_vault_immutable on public.sync_vault;
create trigger sync_vault_immutable before update on public.sync_vault
  for each row execute function public.sync_vault_immutable();

-- Les anciennes tables (champs en clair) sont supprimées, une seule fois : une table qui a
-- déjà `payload` n'est pas touchée, la migration se rejoue sans rien perdre.
do $$
declare t text;
begin
  foreach t in array array['sync_academic_terms', 'sync_courses', 'sync_theory_items', 'sync_exercise_series', 'sync_exercises', 'sync_sub_questions', 'sync_study_sessions', 'sync_exams', 'sync_planned_sessions', 'sync_linked_tasks', 'sync_linked_calendar_events', 'sync_academic_milestones', 'sync_past_exams', 'sync_mistakes', 'sync_saved_resources'] loop
    if exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = t)
       and not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and column_name = 'payload') then
      execute format('drop table public.%I cascade', t);
    end if;
  end loop;
end;
$$;

-- La garde : le propriétaire et la clé d'une ligne ne changent pas ; une écriture plus
-- ancienne que la ligne est ignorée ; le serveur pose server_updated_at.
create or replace function public.sync_guard()
returns trigger
language plpgsql
as $$
begin
  -- Seule la clé du coffre actuel est acceptée : un appareil resté sur une clé
  -- d'avant une réinitialisation ne peut plus rien écrire.
  if not exists (select 1 from public.sync_vault v where v.user_id = new.user_id and v.key_id = new.key_id) then
    raise exception 'clé périmée : ajoute de nouveau cet appareil' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' then
    if new.user_id is distinct from old.user_id then
      raise exception 'une ligne ne change pas de propriétaire' using errcode = '42501';
    end if;
    if new.key_id is distinct from old.key_id then
      raise exception 'une ligne ne change pas de clé : réinitialise le coffre' using errcode = '42501';
    end if;
    -- Écriture plus ancienne que la ligne : ignorée, la version récente reste.
    if new.updated_at < old.updated_at then
      return old;
    end if;
  end if;
  new.server_updated_at := clock_timestamp();
  return new;
end;
$$;

-- AcademicTerm
create table if not exists public.sync_academic_terms (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  updated_at        timestamptz not null,
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now(),
  payload           bytea,
  key_id            text not null check (key_id ~ '^[0-9a-f]{32}$'),
  constraint sync_academic_terms_payload_check check (deleted_at is not null or payload is not null)
);

create index if not exists sync_academic_terms_pull_idx on public.sync_academic_terms (user_id, server_updated_at);

alter table public.sync_academic_terms enable row level security;

drop policy if exists sync_academic_terms_owner on public.sync_academic_terms;
create policy sync_academic_terms_owner on public.sync_academic_terms
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_academic_terms_guard on public.sync_academic_terms;
create trigger sync_academic_terms_guard before insert or update on public.sync_academic_terms
  for each row execute function public.sync_guard();

-- Course
create table if not exists public.sync_courses (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  updated_at        timestamptz not null,
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now(),
  payload           bytea,
  key_id            text not null check (key_id ~ '^[0-9a-f]{32}$'),
  constraint sync_courses_payload_check check (deleted_at is not null or payload is not null)
);

create index if not exists sync_courses_pull_idx on public.sync_courses (user_id, server_updated_at);

alter table public.sync_courses enable row level security;

drop policy if exists sync_courses_owner on public.sync_courses;
create policy sync_courses_owner on public.sync_courses
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_courses_guard on public.sync_courses;
create trigger sync_courses_guard before insert or update on public.sync_courses
  for each row execute function public.sync_guard();

-- TheoryItem
create table if not exists public.sync_theory_items (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  updated_at        timestamptz not null,
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now(),
  payload           bytea,
  key_id            text not null check (key_id ~ '^[0-9a-f]{32}$'),
  constraint sync_theory_items_payload_check check (deleted_at is not null or payload is not null)
);

create index if not exists sync_theory_items_pull_idx on public.sync_theory_items (user_id, server_updated_at);

alter table public.sync_theory_items enable row level security;

drop policy if exists sync_theory_items_owner on public.sync_theory_items;
create policy sync_theory_items_owner on public.sync_theory_items
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_theory_items_guard on public.sync_theory_items;
create trigger sync_theory_items_guard before insert or update on public.sync_theory_items
  for each row execute function public.sync_guard();

-- ExerciseSeries
create table if not exists public.sync_exercise_series (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  updated_at        timestamptz not null,
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now(),
  payload           bytea,
  key_id            text not null check (key_id ~ '^[0-9a-f]{32}$'),
  constraint sync_exercise_series_payload_check check (deleted_at is not null or payload is not null)
);

create index if not exists sync_exercise_series_pull_idx on public.sync_exercise_series (user_id, server_updated_at);

alter table public.sync_exercise_series enable row level security;

drop policy if exists sync_exercise_series_owner on public.sync_exercise_series;
create policy sync_exercise_series_owner on public.sync_exercise_series
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_exercise_series_guard on public.sync_exercise_series;
create trigger sync_exercise_series_guard before insert or update on public.sync_exercise_series
  for each row execute function public.sync_guard();

-- Exercise
create table if not exists public.sync_exercises (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  updated_at        timestamptz not null,
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now(),
  payload           bytea,
  key_id            text not null check (key_id ~ '^[0-9a-f]{32}$'),
  constraint sync_exercises_payload_check check (deleted_at is not null or payload is not null)
);

create index if not exists sync_exercises_pull_idx on public.sync_exercises (user_id, server_updated_at);

alter table public.sync_exercises enable row level security;

drop policy if exists sync_exercises_owner on public.sync_exercises;
create policy sync_exercises_owner on public.sync_exercises
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_exercises_guard on public.sync_exercises;
create trigger sync_exercises_guard before insert or update on public.sync_exercises
  for each row execute function public.sync_guard();

-- SubQuestion
create table if not exists public.sync_sub_questions (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  updated_at        timestamptz not null,
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now(),
  payload           bytea,
  key_id            text not null check (key_id ~ '^[0-9a-f]{32}$'),
  constraint sync_sub_questions_payload_check check (deleted_at is not null or payload is not null)
);

create index if not exists sync_sub_questions_pull_idx on public.sync_sub_questions (user_id, server_updated_at);

alter table public.sync_sub_questions enable row level security;

drop policy if exists sync_sub_questions_owner on public.sync_sub_questions;
create policy sync_sub_questions_owner on public.sync_sub_questions
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_sub_questions_guard on public.sync_sub_questions;
create trigger sync_sub_questions_guard before insert or update on public.sync_sub_questions
  for each row execute function public.sync_guard();

-- StudySession
create table if not exists public.sync_study_sessions (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  updated_at        timestamptz not null,
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now(),
  payload           bytea,
  key_id            text not null check (key_id ~ '^[0-9a-f]{32}$'),
  constraint sync_study_sessions_payload_check check (deleted_at is not null or payload is not null)
);

create index if not exists sync_study_sessions_pull_idx on public.sync_study_sessions (user_id, server_updated_at);

alter table public.sync_study_sessions enable row level security;

drop policy if exists sync_study_sessions_owner on public.sync_study_sessions;
create policy sync_study_sessions_owner on public.sync_study_sessions
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_study_sessions_guard on public.sync_study_sessions;
create trigger sync_study_sessions_guard before insert or update on public.sync_study_sessions
  for each row execute function public.sync_guard();

-- Exam
create table if not exists public.sync_exams (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  updated_at        timestamptz not null,
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now(),
  payload           bytea,
  key_id            text not null check (key_id ~ '^[0-9a-f]{32}$'),
  constraint sync_exams_payload_check check (deleted_at is not null or payload is not null)
);

create index if not exists sync_exams_pull_idx on public.sync_exams (user_id, server_updated_at);

alter table public.sync_exams enable row level security;

drop policy if exists sync_exams_owner on public.sync_exams;
create policy sync_exams_owner on public.sync_exams
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_exams_guard on public.sync_exams;
create trigger sync_exams_guard before insert or update on public.sync_exams
  for each row execute function public.sync_guard();

-- PlannedSession
create table if not exists public.sync_planned_sessions (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  updated_at        timestamptz not null,
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now(),
  payload           bytea,
  key_id            text not null check (key_id ~ '^[0-9a-f]{32}$'),
  constraint sync_planned_sessions_payload_check check (deleted_at is not null or payload is not null)
);

create index if not exists sync_planned_sessions_pull_idx on public.sync_planned_sessions (user_id, server_updated_at);

alter table public.sync_planned_sessions enable row level security;

drop policy if exists sync_planned_sessions_owner on public.sync_planned_sessions;
create policy sync_planned_sessions_owner on public.sync_planned_sessions
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_planned_sessions_guard on public.sync_planned_sessions;
create trigger sync_planned_sessions_guard before insert or update on public.sync_planned_sessions
  for each row execute function public.sync_guard();

-- LinkedTask
create table if not exists public.sync_linked_tasks (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  updated_at        timestamptz not null,
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now(),
  payload           bytea,
  key_id            text not null check (key_id ~ '^[0-9a-f]{32}$'),
  constraint sync_linked_tasks_payload_check check (deleted_at is not null or payload is not null)
);

create index if not exists sync_linked_tasks_pull_idx on public.sync_linked_tasks (user_id, server_updated_at);

alter table public.sync_linked_tasks enable row level security;

drop policy if exists sync_linked_tasks_owner on public.sync_linked_tasks;
create policy sync_linked_tasks_owner on public.sync_linked_tasks
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_linked_tasks_guard on public.sync_linked_tasks;
create trigger sync_linked_tasks_guard before insert or update on public.sync_linked_tasks
  for each row execute function public.sync_guard();

-- LinkedCalendarEvent
create table if not exists public.sync_linked_calendar_events (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  updated_at        timestamptz not null,
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now(),
  payload           bytea,
  key_id            text not null check (key_id ~ '^[0-9a-f]{32}$'),
  constraint sync_linked_calendar_events_payload_check check (deleted_at is not null or payload is not null)
);

create index if not exists sync_linked_calendar_events_pull_idx on public.sync_linked_calendar_events (user_id, server_updated_at);

alter table public.sync_linked_calendar_events enable row level security;

drop policy if exists sync_linked_calendar_events_owner on public.sync_linked_calendar_events;
create policy sync_linked_calendar_events_owner on public.sync_linked_calendar_events
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_linked_calendar_events_guard on public.sync_linked_calendar_events;
create trigger sync_linked_calendar_events_guard before insert or update on public.sync_linked_calendar_events
  for each row execute function public.sync_guard();

-- AcademicMilestone
create table if not exists public.sync_academic_milestones (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  updated_at        timestamptz not null,
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now(),
  payload           bytea,
  key_id            text not null check (key_id ~ '^[0-9a-f]{32}$'),
  constraint sync_academic_milestones_payload_check check (deleted_at is not null or payload is not null)
);

create index if not exists sync_academic_milestones_pull_idx on public.sync_academic_milestones (user_id, server_updated_at);

alter table public.sync_academic_milestones enable row level security;

drop policy if exists sync_academic_milestones_owner on public.sync_academic_milestones;
create policy sync_academic_milestones_owner on public.sync_academic_milestones
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_academic_milestones_guard on public.sync_academic_milestones;
create trigger sync_academic_milestones_guard before insert or update on public.sync_academic_milestones
  for each row execute function public.sync_guard();

-- PastExam
create table if not exists public.sync_past_exams (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  updated_at        timestamptz not null,
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now(),
  payload           bytea,
  key_id            text not null check (key_id ~ '^[0-9a-f]{32}$'),
  constraint sync_past_exams_payload_check check (deleted_at is not null or payload is not null)
);

create index if not exists sync_past_exams_pull_idx on public.sync_past_exams (user_id, server_updated_at);

alter table public.sync_past_exams enable row level security;

drop policy if exists sync_past_exams_owner on public.sync_past_exams;
create policy sync_past_exams_owner on public.sync_past_exams
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_past_exams_guard on public.sync_past_exams;
create trigger sync_past_exams_guard before insert or update on public.sync_past_exams
  for each row execute function public.sync_guard();

-- Mistake
create table if not exists public.sync_mistakes (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  updated_at        timestamptz not null,
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now(),
  payload           bytea,
  key_id            text not null check (key_id ~ '^[0-9a-f]{32}$'),
  constraint sync_mistakes_payload_check check (deleted_at is not null or payload is not null)
);

create index if not exists sync_mistakes_pull_idx on public.sync_mistakes (user_id, server_updated_at);

alter table public.sync_mistakes enable row level security;

drop policy if exists sync_mistakes_owner on public.sync_mistakes;
create policy sync_mistakes_owner on public.sync_mistakes
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_mistakes_guard on public.sync_mistakes;
create trigger sync_mistakes_guard before insert or update on public.sync_mistakes
  for each row execute function public.sync_guard();

-- SavedResource
create table if not exists public.sync_saved_resources (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  updated_at        timestamptz not null,
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now(),
  payload           bytea,
  key_id            text not null check (key_id ~ '^[0-9a-f]{32}$'),
  constraint sync_saved_resources_payload_check check (deleted_at is not null or payload is not null)
);

create index if not exists sync_saved_resources_pull_idx on public.sync_saved_resources (user_id, server_updated_at);

alter table public.sync_saved_resources enable row level security;

drop policy if exists sync_saved_resources_owner on public.sync_saved_resources;
create policy sync_saved_resources_owner on public.sync_saved_resources
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_saved_resources_guard on public.sync_saved_resources;
create trigger sync_saved_resources_guard before insert or update on public.sync_saved_resources
  for each row execute function public.sync_guard();

-- « Réinitialiser le coffre » : toutes les lignes chiffrées du compte et son coffre, en une
-- transaction (security invoker : les politiques RLS ne laissent effacer que les siennes).
create or replace function public.sync_reset_vault()
returns void
language plpgsql
security invoker
as $$
begin
  delete from public.sync_academic_terms where user_id = auth.uid();
  delete from public.sync_courses where user_id = auth.uid();
  delete from public.sync_theory_items where user_id = auth.uid();
  delete from public.sync_exercise_series where user_id = auth.uid();
  delete from public.sync_exercises where user_id = auth.uid();
  delete from public.sync_sub_questions where user_id = auth.uid();
  delete from public.sync_study_sessions where user_id = auth.uid();
  delete from public.sync_exams where user_id = auth.uid();
  delete from public.sync_planned_sessions where user_id = auth.uid();
  delete from public.sync_linked_tasks where user_id = auth.uid();
  delete from public.sync_linked_calendar_events where user_id = auth.uid();
  delete from public.sync_academic_milestones where user_id = auth.uid();
  delete from public.sync_past_exams where user_id = auth.uid();
  delete from public.sync_mistakes where user_id = auth.uid();
  delete from public.sync_saved_resources where user_id = auth.uid();
  delete from public.sync_vault where user_id = auth.uid();
end;
$$;

revoke all on function public.sync_reset_vault() from public, anon;
grant execute on function public.sync_reset_vault() to authenticated;

-- Les appareils ouverts apprennent les écritures des autres sans attendre.
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_academic_terms') then
    alter publication supabase_realtime add table public.sync_academic_terms;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_courses') then
    alter publication supabase_realtime add table public.sync_courses;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_theory_items') then
    alter publication supabase_realtime add table public.sync_theory_items;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_exercise_series') then
    alter publication supabase_realtime add table public.sync_exercise_series;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_exercises') then
    alter publication supabase_realtime add table public.sync_exercises;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_sub_questions') then
    alter publication supabase_realtime add table public.sync_sub_questions;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_study_sessions') then
    alter publication supabase_realtime add table public.sync_study_sessions;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_exams') then
    alter publication supabase_realtime add table public.sync_exams;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_planned_sessions') then
    alter publication supabase_realtime add table public.sync_planned_sessions;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_linked_tasks') then
    alter publication supabase_realtime add table public.sync_linked_tasks;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_linked_calendar_events') then
    alter publication supabase_realtime add table public.sync_linked_calendar_events;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_academic_milestones') then
    alter publication supabase_realtime add table public.sync_academic_milestones;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_past_exams') then
    alter publication supabase_realtime add table public.sync_past_exams;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_mistakes') then
    alter publication supabase_realtime add table public.sync_mistakes;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_saved_resources') then
    alter publication supabase_realtime add table public.sync_saved_resources;
  end if;
end;
$$;
