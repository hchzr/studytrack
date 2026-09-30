-- Entraide dans un groupe : une question sur un exercice précis, et ses réponses.
--
-- « Je bloque sur 4.3 (b) » : la question porte le cours, la série et
-- l'exercice, pour que la réponse arrive **là** où l'on travaille. Une réponse
-- est une ligne dont `parent_id` pointe la question. Seuls les membres du
-- groupe lisent et écrivent ; chacun ne modifie que ses propres messages
-- (marquer « résolu »), un admin peut en retirer.

create table if not exists public.group_posts (
  id              uuid primary key default gen_random_uuid(),
  group_id        uuid not null references public.study_groups(id) on delete cascade,
  author_id       uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  author_name     text not null default '',
  parent_id       uuid references public.group_posts(id) on delete cascade,
  kind            text not null default 'help' check (kind in ('help', 'reply', 'note')),
  course_code     text not null default '',
  series_number   int,
  exercise_number text not null default '',
  body            text not null check (char_length(body) between 1 and 2000),
  resolved        boolean not null default false,
  created_at      timestamptz not null default now()
);

create index if not exists group_posts_group_idx on public.group_posts (group_id, created_at desc);
create index if not exists group_posts_parent_idx on public.group_posts (parent_id);

alter table public.group_posts enable row level security;

drop policy if exists posts_read on public.group_posts;
create policy posts_read on public.group_posts
  for select using (public.is_group_member(group_id));

drop policy if exists posts_insert on public.group_posts;
create policy posts_insert on public.group_posts
  for insert with check (author_id = auth.uid() and public.is_group_member(group_id));

drop policy if exists posts_update on public.group_posts;
create policy posts_update on public.group_posts
  for update using (author_id = auth.uid()) with check (author_id = auth.uid());

drop policy if exists posts_delete on public.group_posts;
create policy posts_delete on public.group_posts
  for delete using (author_id = auth.uid() or public.is_group_admin(group_id));
