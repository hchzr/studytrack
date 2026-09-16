-- ═══════════════════════════════════════════════════════════════════════════════
--  StudyTrack — vérification de l'état réel du projet Supabase
--
--  À coller dans Supabase ▸ SQL Editor et exécuter. Lecture seule : ce fichier ne
--  modifie rien.
--
--  Il répond aux trois questions qu'on ne peut pas trancher depuis l'app :
--    1. Suis-je membre des groupes que je crois avoir ?
--    2. Les nouvelles tables existent-elles ?
--    3. Les politiques RLS sont-elles bien en place ?
-- ═══════════════════════════════════════════════════════════════════════════════


-- ────────────────────────────────── 1. MES GROUPES ET MES ADHÉSIONS ───────────
-- `mes_adhesions = 0` sur une ligne où `je_suis_createur` vaut `true` signale
-- exactement le défaut qui fait échouer la présence et l'avancement : le groupe
-- existe côté serveur, mais sans son créateur. L'app le répare au prochain
-- « Réparer et réessayer ».
select g.id,
       g.name,
       g.invite_code,
       g.created_by = auth.uid() as je_suis_createur,
       (select count(*) from public.group_members m
         where m.group_id = g.id and m.user_id = auth.uid()) as mes_adhesions,
       (select count(*) from public.group_members m where m.group_id = g.id) as membres,
       (select count(*) from public.item_completion i where i.group_id = g.id) as avancements,
       (select count(*) from public.presence p where p.group_id = g.id) as presences
  from public.study_groups g
 order by g.created_at;


-- ────────────────────────────────────────────── 2. TABLES ATTENDUES ──────────
-- Les huit tables doivent toutes répondre `true`.
select tablename,
       exists (select 1 from information_schema.tables t
                where t.table_schema = 'public' and t.table_name = tablename) as presente
  from unnest(array['profiles', 'study_groups', 'group_members', 'planned_sessions',
                    'series_completion', 'item_completion', 'group_courses',
                    'member_courses', 'presence']) as tablename;


-- ──────────────────────────────────────────────── 3. POLITIQUES RLS ──────────
-- Chaque table doit avoir au moins une politique. Une table `rowsecurity = true`
-- sans politique refuse **tout** — c'est le cas qui produit un 42501.
select c.relname as table_name,
       c.relrowsecurity as rls_activee,
       count(p.policyname) as politiques
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  left join pg_policies p on p.schemaname = 'public' and p.tablename = c.relname
 where n.nspname = 'public'
   and c.relkind = 'r'
   and c.relname in ('profiles', 'study_groups', 'group_members', 'planned_sessions',
                     'series_completion', 'item_completion', 'group_courses',
                     'member_courses', 'presence')
 group by c.relname, c.relrowsecurity
 order by c.relname;


-- ─────────────────────────────────────────────── 4. DROITS DE TABLE ──────────
-- Un `42501 permission denied for table …` sur une **lecture** ne vient pas des
-- politiques RLS — elles filtrent en silence — mais d'un droit absent.
select table_name, grantee, string_agg(privilege_type, ', ' order by privilege_type) as privileges
  from information_schema.role_table_grants
 where table_schema = 'public'
   and grantee in ('anon', 'authenticated')
   and table_name in ('item_completion', 'group_courses', 'member_courses', 'presence')
 group by table_name, grantee
 order by table_name, grantee;
