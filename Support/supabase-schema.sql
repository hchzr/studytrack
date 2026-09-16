-- ═══════════════════════════════════════════════════════════════════════════════
--  StudyTrack — schéma Supabase complet
--
--  À exécuter dans Supabase ▸ SQL Editor, en une seule fois. Idempotent : tu peux
--  le relancer sans casser ce qui existe déjà.
--
--  Corrige l'erreur PGRST205 « Could not find the table 'public.group_members'
--  in the schema cache » : elle signifie que les tables n'ont jamais été créées.
--
--  Contenu :
--    1. Tables                    (SPEC.md §7.1)
--    2. Fonction de classement    (appelée par le code, absente du SPEC)
--    3. Création automatique du profil à l'inscription
--    4. Row-Level Security        (règles du SPEC §7.3, écrites ici)
--    5. Rechargement du cache PostgREST
--
--  Depuis l'ajout des matières multiples, trois tables s'y trouvent en plus :
--    group_courses   — les matières que le groupe travaille
--    member_courses  — celles que chaque membre suit parmi elles
--    presence        — « untel travaille sur CS-250 en ce moment »
-- ═══════════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────── 1. TABLES ────

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  avatar_url text,
  sciper text,
  created_at timestamptz default now()
);

create table if not exists public.courses_catalog (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  credits numeric,
  weekly_lecture_hours numeric,
  weekly_exercise_hours numeric
);

create table if not exists public.study_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  course_code text,
  invite_code text unique not null,
  is_public boolean default false,
  created_by uuid references public.profiles(id),
  created_at timestamptz default now()
);

create table if not exists public.group_members (
  group_id uuid references public.study_groups(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  role text default 'member',
  joined_at timestamptz default now(),
  primary key (group_id, user_id)
);

create table if not exists public.planned_sessions (
  id uuid primary key default gen_random_uuid(),
  group_id uuid references public.study_groups(id) on delete cascade,
  course_code text,
  title text not null,
  starts_at timestamptz not null,
  duration_minutes int not null,
  location text,
  created_by uuid references public.profiles(id),
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table if not exists public.session_rsvps (
  session_id uuid references public.planned_sessions(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  status text default 'going',
  primary key (session_id, user_id)
);

create table if not exists public.study_log_public (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete cascade,
  group_id uuid references public.study_groups(id) on delete cascade,
  course_code text,
  task_type text,
  started_at timestamptz not null,
  duration_seconds int not null
);

create table if not exists public.series_completion (
  group_id uuid references public.study_groups(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  course_code text,
  series_number int,
  completed_at timestamptz default now(),
  primary key (group_id, user_id, course_code, series_number)
);

create table if not exists public.item_completion (
  group_id uuid references public.study_groups(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  course_code text not null,
  item_kind text not null,      -- 'exercise' | 'theory'
  item_number text not null,    -- « 3.2 », « 1.1 »
  completed_at timestamptz default now(),
  primary key (group_id, user_id, course_code, item_kind, item_number)
);

create table if not exists public.xp_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete cascade,
  event text not null,
  amount int not null,
  created_at timestamptz default now()
);

-- ───────────────────────────────────────────── MATIÈRES DU GROUPE ─────────────
-- `study_groups.course_code` ne porte que la **première** matière, pour rester
-- lisible par les versions antérieures de l'app. La liste complète est ici.
create table if not exists public.group_courses (
  group_id uuid references public.study_groups(id) on delete cascade,
  course_code text not null,
  added_at timestamptz default now(),
  primary key (group_id, course_code)
);

-- Les matières que **chaque membre** suit parmi celles du groupe. Un membre
-- inscrit à deux cours sur cinq ne doit pas apparaître avec un zéro partout sur
-- les trois autres.
create table if not exists public.member_courses (
  group_id uuid references public.study_groups(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  course_code text not null,
  primary key (group_id, user_id, course_code)
);

-- ──────────────────────────────────────────────── PRÉSENCE EN DIRECT ─────────
-- Éphémère : une ligne par membre et par groupe, remplacée à chaque battement.
-- `updated_at` est le seul juge — l'app considère qu'un membre travaille tant
-- qu'il est récent, ce qui éteint tout seul un téléphone en veille ou une app
-- tuée, sans fausse déclaration.
create table if not exists public.presence (
  group_id uuid references public.study_groups(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  course_code text,
  task_label text,
  target text,
  started_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

-- Index utiles aux requêtes de l'app.
create index if not exists study_log_public_group_idx on public.study_log_public (group_id, started_at desc);
create index if not exists series_completion_group_idx on public.series_completion (group_id);
create index if not exists group_members_user_idx on public.group_members (user_id);
create index if not exists group_courses_group_idx on public.group_courses (group_id);
create index if not exists member_courses_group_idx on public.member_courses (group_id, user_id);
create index if not exists presence_group_idx on public.presence (group_id, updated_at desc);


-- ─────────────────────────────────────────── 2. CLASSEMENT (RPC attendu) ───────
-- L'app appelle client.rpc("group_leaderboard", params: ["p_group_id": …]) et
-- décode exactement ces cinq colonnes. Sans cette fonction le classement échoue
-- en silence — l'appel est enveloppé dans un `try?`.

create or replace function public.group_leaderboard(p_group_id uuid)
returns table (
  user_id uuid,
  display_name text,
  weekly_seconds bigint,
  total_seconds bigint,
  series_completed bigint
)
language sql
security definer
set search_path = public
as $$
  select m.user_id,
         p.display_name,
         coalesce(sum(l.duration_seconds) filter (
           where l.started_at >= now() - interval '7 days'), 0)::bigint as weekly_seconds,
         coalesce(sum(l.duration_seconds), 0)::bigint                        as total_seconds,
         coalesce((select count(*) from public.series_completion s
                   where s.group_id = p_group_id and s.user_id = m.user_id), 0)::bigint
                                                                             as series_completed
  from public.group_members m
  left join public.study_log_public l
         on l.user_id = m.user_id and l.group_id = p_group_id
  left join public.profiles p on p.id = m.user_id
  where m.group_id = p_group_id
  group by m.user_id, p.display_name;
$$;


-- ───────────────────────────── 3. PROFIL CRÉÉ À L'INSCRIPTION ─────────────────
-- `study_groups.created_by` et `group_members.user_id` référencent profiles(id).
-- Le code crée désormais le profil avant le groupe, mais ce déclencheur garantit
-- qu'il existe dès l'inscription, quel que soit l'ordre des appels.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1))
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Rattrapage des comptes **déjà existants**.
--
-- Le déclencheur ci-dessus ne se déclenche qu'à l'inscription. Un compte créé
-- AVANT l'exécution de ce fichier n'a donc aucune ligne `profiles` — et comme
-- `study_groups.created_by` référence `profiles(id)`, la création d'un groupe
-- échoue sur une violation de clé étrangère (23503). C'est la cause des
-- « groupes qui ne s'affichent pas » alors que le SQL a bien été exécuté.
insert into public.profiles (id, display_name)
select u.id,
       coalesce(u.raw_user_meta_data->>'full_name', split_part(u.email, '@', 1))
from auth.users u
on conflict (id) do nothing;


-- ──────────────────────────────────────────────── 4. ROW-LEVEL SECURITY ───────
-- Sans ces politiques, les tables sont ouvertes à quiconque possède la clé
-- `anon` — qui est publique par conception.

alter table public.profiles          enable row level security;
alter table public.courses_catalog   enable row level security;
alter table public.study_groups      enable row level security;
alter table public.group_members     enable row level security;
alter table public.planned_sessions  enable row level security;
alter table public.session_rsvps     enable row level security;
alter table public.study_log_public  enable row level security;
alter table public.series_completion enable row level security;
alter table public.xp_events         enable row level security;

-- Est-on membre de ce groupe ? `security definer` pour éviter la récursion
-- infinie : la politique de group_members ne peut pas interroger group_members.
create or replace function public.is_group_member(p_group_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.group_members
    where group_id = p_group_id and user_id = auth.uid()
  );
$$;

-- profiles : lisible par tout utilisateur connecté, modifiable par son propriétaire.
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles
  for select to authenticated using (true);

drop policy if exists profiles_write on public.profiles;
create policy profiles_write on public.profiles
  for all to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- catalogue : lisible par tous, modifiable par personne depuis l'app.
drop policy if exists catalog_read on public.courses_catalog;
create policy catalog_read on public.courses_catalog
  for select to authenticated using (true);

-- study_groups : lisible par tout connecté — c'est le code d'invitation qui
-- protège, pas la lecture. Création réservée au créateur déclaré.
drop policy if exists groups_read on public.study_groups;
create policy groups_read on public.study_groups
  for select to authenticated using (true);

drop policy if exists groups_insert on public.study_groups;
create policy groups_insert on public.study_groups
  for insert to authenticated with check (created_by = auth.uid());

drop policy if exists groups_update on public.study_groups;
create policy groups_update on public.study_groups
  for update to authenticated using (created_by = auth.uid());

drop policy if exists groups_delete on public.study_groups;
create policy groups_delete on public.study_groups
  for delete to authenticated using (created_by = auth.uid());

-- group_members : visible par les membres du groupe ; on s'ajoute soi-même.
-- Ma propre ligne est **toujours** visible, membre ou pas encore : c'est ce qui
-- permet à l'insertion de mon adhésion de renvoyer sa ligne (`RETURNING`) sans
-- que `is_group_member` — qui ne voit pas encore la ligne dans la même
-- instruction — ne fasse échouer l'écriture en 42501.
drop policy if exists members_read on public.group_members;
create policy members_read on public.group_members
  for select to authenticated
  using (user_id = auth.uid() or public.is_group_member(group_id));

drop policy if exists members_join on public.group_members;
create policy members_join on public.group_members
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists members_leave on public.group_members;
create policy members_leave on public.group_members
  for delete to authenticated using (user_id = auth.uid());

-- Administration des membres : un **administrateur** du groupe peut retirer ou
-- rétrograder quelqu'un. Sans ces politiques, seul « se retirer soi-même » était
-- possible — la gestion des membres ne pouvait pas exister.
create or replace function public.is_group_admin(p_group_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.group_members
    where group_id = p_group_id
      and user_id = auth.uid()
      and role = 'admin'
  );
$$;

-- Le **créateur** du groupe est administrateur de droit.
--
-- Sans cette fonction, un créateur dont la ligne `group_members` manque (insertion
-- échouée lors de la création, ou groupe créé avant la correction) ne pouvait plus
-- jamais se réinsérer comme administrateur : `members_admin_update` exige
-- `is_group_admin`, qui exige la ligne manquante. Verrou parfait.
create or replace function public.is_group_creator(p_group_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.study_groups
    where id = p_group_id and created_by = auth.uid()
  );
$$;

drop policy if exists members_admin_delete on public.group_members;
create policy members_admin_delete on public.group_members
  for delete to authenticated
  using (user_id = auth.uid()
         or public.is_group_admin(group_id)
         or public.is_group_creator(group_id));

drop policy if exists members_admin_update on public.group_members;
create policy members_admin_update on public.group_members
  for update to authenticated
  using (public.is_group_admin(group_id) or public.is_group_creator(group_id))
  with check (public.is_group_admin(group_id) or public.is_group_creator(group_id));

-- planning partagé : réservé aux membres du groupe.
drop policy if exists planned_read on public.planned_sessions;
create policy planned_read on public.planned_sessions
  for select to authenticated
  using (group_id is null or public.is_group_member(group_id));

drop policy if exists planned_insert on public.planned_sessions;
create policy planned_insert on public.planned_sessions
  for insert to authenticated
  with check (created_by = auth.uid()
              and (group_id is null or public.is_group_member(group_id)));

drop policy if exists planned_update on public.planned_sessions;
create policy planned_update on public.planned_sessions
  for update to authenticated using (created_by = auth.uid());

drop policy if exists planned_delete on public.planned_sessions;
create policy planned_delete on public.planned_sessions
  for delete to authenticated using (created_by = auth.uid());

-- RSVP : chacun ne gère que le sien, mais les lit tous dans son groupe.
drop policy if exists rsvp_read on public.session_rsvps;
create policy rsvp_read on public.session_rsvps
  for select to authenticated
  using (exists (select 1 from public.planned_sessions ps
                 where ps.id = session_id
                   and (ps.group_id is null or public.is_group_member(ps.group_id))));

drop policy if exists rsvp_write on public.session_rsvps;
create policy rsvp_write on public.session_rsvps
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- temps publié : lisible par les membres du même groupe, écrit par son auteur.
drop policy if exists log_read on public.study_log_public;
create policy log_read on public.study_log_public
  for select to authenticated using (public.is_group_member(group_id));

drop policy if exists log_insert on public.study_log_public;
create policy log_insert on public.study_log_public
  for insert to authenticated
  with check (user_id = auth.uid() and public.is_group_member(group_id));

drop policy if exists log_delete on public.study_log_public;
create policy log_delete on public.study_log_public
  for delete to authenticated using (user_id = auth.uid());

-- avancement des séries : même principe.
drop policy if exists series_read on public.series_completion;
create policy series_read on public.series_completion
  for select to authenticated using (public.is_group_member(group_id));

drop policy if exists series_write on public.series_completion;
create policy series_write on public.series_completion
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and public.is_group_member(group_id));

-- Avancement détaillé : mêmes règles que series_completion.
alter table public.item_completion enable row level security;

drop policy if exists item_read on public.item_completion;
create policy item_read on public.item_completion
  for select to authenticated using (public.is_group_member(group_id));

drop policy if exists item_write on public.item_completion;
create policy item_write on public.item_completion
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and public.is_group_member(group_id));

-- Matières du groupe : lisibles par ses membres, modifiées par ses administrateurs.
--
-- Un simple membre ne peut pas écrire la liste : elle est commune, et la laisser
-- ouverte à tous ferait qu'un désaccord sur les matières se règle par une course
-- à l'écriture. Chacun garde la main sur **sa** liste, juste en dessous.
alter table public.group_courses enable row level security;

drop policy if exists group_courses_read on public.group_courses;
create policy group_courses_read on public.group_courses
  for select to authenticated using (public.is_group_member(group_id));

drop policy if exists group_courses_write on public.group_courses;
create policy group_courses_write on public.group_courses
  for all to authenticated
  using (public.is_group_admin(group_id))
  with check (public.is_group_admin(group_id));

-- Matières suivies par un membre : visibles des membres du groupe (c'est ce qui
-- explique qu'un membre n'apparaisse pas dans un tableau), modifiées par lui seul.
alter table public.member_courses enable row level security;

drop policy if exists member_courses_read on public.member_courses;
create policy member_courses_read on public.member_courses
  for select to authenticated using (public.is_group_member(group_id));

drop policy if exists member_courses_write on public.member_courses;
create policy member_courses_write on public.member_courses
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and public.is_group_member(group_id));

-- Présence : mêmes règles que l'avancement — lisible dans le groupe, écrite par
-- son seul auteur.
alter table public.presence enable row level security;

drop policy if exists presence_read on public.presence;
create policy presence_read on public.presence
  for select to authenticated
  using (user_id = auth.uid() or public.is_group_member(group_id));

drop policy if exists presence_write on public.presence;
create policy presence_write on public.presence
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and public.is_group_member(group_id));

-- XP : strictement personnel.
drop policy if exists xp_own on public.xp_events;
create policy xp_own on public.xp_events
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());


-- ───────────────────────────────────────────── 4 bis. DROITS DE TABLE ────────
-- Supabase accorde ces droits par défaut aux rôles `anon` et `authenticated` sur
-- les tables de `public`. Les redonner ici, c'est rendre le fichier **complet** :
-- une table créée dans un contexte où les privilèges par défaut diffèrent se
-- traduisait par un `42501 permission denied for table …` sur une simple lecture —
-- message que les politiques RLS ne produisent jamais, elles filtrent en silence.

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant select on all tables in schema public to anon;
grant execute on all functions in schema public to anon, authenticated;


-- ─────────────────────────────── 5. CACHE POSTGREST ──────────────────────────
-- PostgREST garde un cache du schéma. Après avoir créé des tables à la main, il
-- peut continuer à répondre PGRST205 : ce rechargement le force à relire.

-- Ménage de la présence.
--
-- L'app filtre déjà sur `updated_at` et n'affiche personne au-delà de quelques
-- minutes, donc **rien ne casse** si cette fonction n'est jamais appelée : les
-- lignes périmées sont simplement invisibles. Elle sert à ne pas laisser
-- s'accumuler une ligne par personne et par groupe indéfiniment.
create or replace function public.presence_sweep()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.presence where updated_at < now() - interval '1 hour';
$$;

-- Un passage dès maintenant : le script est idempotent, on en profite.
select public.presence_sweep();

-- Pour l'automatiser, active pg_cron (Database ▸ Extensions) puis :
--   select cron.schedule('presence-sweep', '*/15 * * * *',
--                        $$select public.presence_sweep()$$);
-- Sans pg_cron, relancer ce fichier de temps en temps suffit.

-- ───────────────────────────────────── 6. VÉRIFICATION (à lancer à part) ──────
-- Colle ce bloc dans le SQL Editor pour voir l'état réel, plutôt que de le
-- déduire d'un message d'erreur :
--
--   -- Suis-je membre de mes groupes ?
--   select g.id, g.name, g.created_by = auth.uid() as je_suis_createur,
--          (select count(*) from public.group_members m
--            where m.group_id = g.id and m.user_id = auth.uid()) as mes_adhesions
--     from public.study_groups g;
--
--   -- Les politiques existent-elles ?
--   select tablename, policyname from pg_policies
--    where schemaname = 'public' order by tablename, policyname;
--
-- `mes_adhesions = 0` sur une ligne où `je_suis_createur` est vrai signifie que
-- l'insertion de l'adhésion a échoué à la création : c'est la cause du refus RLS
-- sur `presence` et sur l'avancement.

notify pgrst, 'reload schema';
