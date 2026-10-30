#!/usr/bin/env bash
#
# Joue la migration de synchronisation dans un Postgres jetable et vérifie son
# comportement : isolement par propriétaire (RLS), la plus récente écriture gagne,
# curseur serveur, changement de propriétaire refusé, rejouable.
#
# Supabase est simulé au minimum : schéma `auth` (users, uid() lu dans un
# réglage de session), rôle `authenticated`, publication `supabase_realtime`.
#
#   windows/scripts/test-migration.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATION="$ROOT/supabase/migrations/20261030000000_user_data_sync.sql"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/studytrack-pg.XXXXXX")"
PORT=55432
cleanup() { pg_ctl -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

initdb -D "$WORK/data" -U postgres --auth=trust >/dev/null
pg_ctl -D "$WORK/data" -o "-p $PORT -k $WORK -c listen_addresses=''" -l "$WORK/log" -w start >/dev/null
PSQL=(psql -h "$WORK" -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -q -X)

"${PSQL[@]}" <<'SQL'
create schema auth;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create role authenticated nologin;
grant usage on schema public, auth to authenticated;
grant execute on function auth.uid() to authenticated;
create publication supabase_realtime;
alter default privileges in schema public grant all on tables to authenticated;
insert into auth.users values ('00000000-0000-0000-0000-00000000000a'), ('00000000-0000-0000-0000-00000000000b');
SQL

"${PSQL[@]}" -f "$MIGRATION"
# Rejouable : une seconde application ne doit rien casser.
"${PSQL[@]}" -f "$MIGRATION"

"${PSQL[@]}" <<'SQL'
\set A '00000000-0000-0000-0000-00000000000a'
\set B '00000000-0000-0000-0000-00000000000b'
\set C '11111111-1111-1111-1111-111111111111'
create function pg_temp.expect(ok boolean, label text) returns void language plpgsql as
  $$ begin if not ok then raise exception 'ÉCHEC : %', label; end if; raise notice 'ok  %', label; end $$;

set role authenticated;
select set_config('request.jwt.claim.sub', :'A', false);

insert into sync_courses (id, name, updated_at) values (:'C', 'Analyse I', '2026-10-30T10:00:00Z');
select pg_temp.expect((select user_id from sync_courses where id = :'C') = :'A', 'user_id posé par défaut');
select pg_temp.expect((select code from sync_courses where id = :'C') = '', 'défauts Swift appliqués');

create temp table t0 as select server_updated_at as s from sync_courses where id = :'C';
select pg_sleep(0.01);

-- Écriture plus récente : acceptée, curseur avancé.
update sync_courses set name = 'Analyse I (v2)', updated_at = '2026-10-30T11:00:00Z' where id = :'C';
select pg_temp.expect((select name from sync_courses where id = :'C') = 'Analyse I (v2)', 'écriture récente acceptée');
select pg_temp.expect((select server_updated_at from sync_courses where id = :'C') > (select s from t0), 'curseur serveur avancé');

-- Écriture plus ancienne (appareil resté hors ligne) : ignorée.
update sync_courses set name = 'périmé', updated_at = '2026-10-30T09:00:00Z' where id = :'C';
select pg_temp.expect((select name from sync_courses where id = :'C') = 'Analyse I (v2)', 'écriture périmée ignorée');

-- Upsert comme le feront les clients.
insert into sync_courses (id, name, updated_at) values (:'C', 'upsert périmé', '2026-10-30T08:00:00Z')
  on conflict (id) do update set name = excluded.name, updated_at = excluded.updated_at;
select pg_temp.expect((select name from sync_courses where id = :'C') = 'Analyse I (v2)', 'upsert périmé ignoré');
insert into sync_courses (id, name, updated_at) values (:'C', 'upsert récent', '2026-10-30T12:00:00Z')
  on conflict (id) do update set name = excluded.name, updated_at = excluded.updated_at;
select pg_temp.expect((select name from sync_courses where id = :'C') = 'upsert récent', 'upsert récent accepté');

-- Le client relit la version gardée dans la réponse (return=representation) :
-- un envoi périmé doit renvoyer la version du serveur, pas la sienne.
create temp table echo as with up as (
  insert into sync_courses (id, name, updated_at) values (:'C', 'encore périmé', '2026-10-30T07:00:00Z')
    on conflict (id) do update set name = excluded.name, updated_at = excluded.updated_at
    returning name, updated_at)
  select * from up;
select pg_temp.expect((select name from echo) = 'upsert récent', 'envoi périmé : la réponse porte la version du serveur');

-- Pierre tombale.
update sync_courses set deleted_at = now(), updated_at = '2026-10-30T13:00:00Z' where id = :'C';
select pg_temp.expect((select deleted_at is not null from sync_courses where id = :'C'), 'pierre tombale enregistrée');

-- Changement de propriétaire refusé.
do $$ begin
  update sync_courses set user_id = '00000000-0000-0000-0000-00000000000b', updated_at = '2026-10-30T14:00:00Z'
    where id = '11111111-1111-1111-1111-111111111111';
  raise exception 'ÉCHEC : changement de propriétaire accepté';
exception when insufficient_privilege then raise notice 'ok  changement de propriétaire refusé';
end $$;

-- L'autre compte ne voit rien, ne peut ni écrire chez A ni usurper user_id.
select set_config('request.jwt.claim.sub', :'B', false);
select pg_temp.expect((select count(*) from sync_courses) = 0, 'RLS : B ne voit pas les lignes de A');
update sync_courses set name = 'piraté' where id = :'C';
do $$ begin
  insert into sync_courses (id, user_id, name) values (gen_random_uuid(), '00000000-0000-0000-0000-00000000000a', 'usurpé');
  raise exception 'ÉCHEC : insertion au nom de A acceptée';
exception when insufficient_privilege then raise notice 'ok  RLS : B ne peut pas écrire au nom de A';
end $$;
do $$ begin
  insert into sync_courses (id, name) values ('11111111-1111-1111-1111-111111111111', 'collision');
  raise exception 'ÉCHEC : collision d''identifiant acceptée';
exception when unique_violation or insufficient_privilege then raise notice 'ok  B ne peut pas reprendre un id de A';
end $$;
select set_config('request.jwt.claim.sub', :'A', false);
select pg_temp.expect((select name from sync_courses where id = :'C') = 'upsert récent', 'RLS : la ligne de A est intacte');

reset role;
select pg_temp.expect((select count(*) from pg_publication_tables where pubname = 'supabase_realtime') = 15, 'les 15 tables sont publiées en temps réel');

-- Suppression du compte : tout part en cascade.
delete from auth.users where id = :'A';
select pg_temp.expect((select count(*) from sync_courses) = 0, 'suppression du compte : données supprimées');
SQL

echo "✅ migration de synchronisation vérifiée"
