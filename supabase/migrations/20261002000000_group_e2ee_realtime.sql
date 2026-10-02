-- Entraide chiffrée de bout en bout, et groupes en temps réel.
--
-- 1. CHIFFREMENT. Les messages de `group_posts` étaient lisibles en clair dans
--    le tableau de bord, les sauvegardes et par quiconque obtiendrait l'accès à
--    la base. Désormais le **corps** d'un message est chiffré sur le téléphone
--    (AES-GCM, une clé par groupe) ; le serveur ne stocke que `ciphertext`.
--
--    La clé du groupe ne transite jamais en clair :
--      • chaque appareil publie une clé publique Curve25519 (`member_keys`) ;
--      • un membre qui détient la clé du groupe la **scelle** pour chaque autre
--        clé publique de membre (ECDH + HKDF + AES-GCM) dans `group_key_shares` ;
--      • `group_key_epochs` désigne, une fois pour toutes, la clé en vigueur —
--        la clé primaire empêche deux membres d'en créer deux en même temps.
--    Rejoindre avec le simple code marche donc toujours : la clé arrive dès
--    qu'un membre qui l'a ouvre l'app.
--
--    Ce qui reste en clair, assumé : l'auteur, la date, le cours et le numéro
--    d'exercice (ce qui range la question), et l'état « résolu ».
--
-- 2. TEMPS RÉEL. Les tables suivies par l'app entrent dans la publication
--    `supabase_realtime` : un message, une présence ou une adhésion arrive sur
--    les téléphones abonnés à l'instant, au lieu du prochain relevé (30 s).
--    Realtime applique les mêmes politiques RLS que les lectures.

-- ─────────────────────────────────────────────── clés publiques ─────────────
create table if not exists public.member_keys (
  user_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  public_key text not null check (char_length(public_key) between 40 and 64),
  created_at timestamptz not null default now(),
  primary key (user_id, public_key)
);

alter table public.member_keys enable row level security;

-- Une clé publique n'a rien de secret : tout compte connecté peut la lire.
drop policy if exists member_keys_read on public.member_keys;
create policy member_keys_read on public.member_keys
  for select to authenticated using (true);

drop policy if exists member_keys_write on public.member_keys;
create policy member_keys_write on public.member_keys
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ─────────────────────────────────────────── clé en vigueur d'un groupe ─────
create table if not exists public.group_key_epochs (
  group_id   uuid primary key references public.study_groups(id) on delete cascade,
  key_id     text not null,
  created_by uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.group_key_epochs enable row level security;

drop policy if exists key_epochs_read on public.group_key_epochs;
create policy key_epochs_read on public.group_key_epochs
  for select to authenticated using (public.is_group_member(group_id));

drop policy if exists key_epochs_insert on public.group_key_epochs;
create policy key_epochs_insert on public.group_key_epochs
  for insert to authenticated
  with check (created_by = auth.uid() and public.is_group_member(group_id));

-- ───────────────────────────────────────────── clés scellées par membre ─────
create table if not exists public.group_key_shares (
  group_id      uuid not null references public.study_groups(id) on delete cascade,
  key_id        text not null,
  recipient_id  uuid not null references public.profiles(id) on delete cascade,
  recipient_key text not null,
  sender_id     uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  sender_key    text not null,
  sealed        text not null,
  created_at    timestamptz not null default now(),
  primary key (group_id, key_id, recipient_key)
);

create index if not exists group_key_shares_recipient_idx on public.group_key_shares (recipient_id);

alter table public.group_key_shares enable row level security;

-- Visibles par les membres : chacun voit quelles clés publiques sont déjà
-- servies (pour ne sceller que ce qui manque). Le contenu scellé n'est
-- ouvrable que par le détenteur de la clé privée destinataire.
drop policy if exists key_shares_read on public.group_key_shares;
create policy key_shares_read on public.group_key_shares
  for select to authenticated using (public.is_group_member(group_id));

-- On ne scelle que pour un **membre** du groupe, en son propre nom.
drop policy if exists key_shares_insert on public.group_key_shares;
create policy key_shares_insert on public.group_key_shares
  for insert to authenticated
  with check (sender_id = auth.uid()
              and public.is_group_member(group_id)
              and exists (select 1 from public.group_members m
                          where m.group_id = group_key_shares.group_id
                            and m.user_id = group_key_shares.recipient_id));

-- ───────────────────────────────────────────── messages chiffrés ────────────
alter table public.group_posts add column if not exists ciphertext text;
alter table public.group_posts add column if not exists key_id text;

-- Un message chiffré n'a plus de corps en clair : la contrainte de longueur
-- porte désormais sur l'un **ou** l'autre.
alter table public.group_posts drop constraint if exists group_posts_body_check;
alter table public.group_posts drop constraint if exists group_posts_content_check;
alter table public.group_posts add constraint group_posts_content_check check (
  (ciphertext is null and char_length(body) between 1 and 2000)
  or (ciphertext is not null and body = '' and char_length(ciphertext) between 1 and 6000)
);

-- ───────────────────────────────────────────── temps réel ───────────────────
-- `replica identity full` : un DELETE transmet l'ancienne ligne entière, donc
-- son `group_id` — sans quoi le filtre `group_id=eq.…` ne la laisse pas passer.
alter table public.group_posts replica identity full;
alter table public.presence replica identity full;
alter table public.group_members replica identity full;

do $$
declare
  t text;
begin
  foreach t in array array['group_posts', 'presence', 'group_members', 'group_key_shares'] loop
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
