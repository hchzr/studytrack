#!/usr/bin/env bash
#
# Joue les migrations de synchronisation dans un Postgres jetable et vérifie leur
# comportement : l'ancienne (champs en clair, appliquée sur le projet) puis la
# chiffrée de bout en bout, qui la remplace. Isolement par propriétaire (RLS), la
# plus récente écriture gagne, curseur serveur, changement de propriétaire ou de
# clé refusé, coffre écrit une fois, réinitialisation, rejouable sans perte.
#
# Supabase est simulé au minimum : schéma `auth` (users, uid() lu dans un
# réglage de session), rôle `authenticated`, publication `supabase_realtime`.
#
#   windows/scripts/test-migration.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OLD_MIGRATION="$ROOT/supabase/migrations/20261030000000_user_data_sync.sql"
MIGRATION="$ROOT/supabase/migrations/20261103000000_sync_e2ee.sql"
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
create role anon nologin;
grant usage on schema public, auth to authenticated;
grant execute on function auth.uid() to authenticated;
create publication supabase_realtime;
alter default privileges in schema public grant all on tables to authenticated;
insert into auth.users values ('00000000-0000-0000-0000-00000000000a'), ('00000000-0000-0000-0000-00000000000b');
SQL

# L'ancienne migration, telle qu'elle est sur le projet, puis la chiffrée par-dessus.
"${PSQL[@]}" -f "$OLD_MIGRATION"
"${PSQL[@]}" -f "$MIGRATION"

"${PSQL[@]}" -v migration="$MIGRATION" <<'SQL'
\set A '00000000-0000-0000-0000-00000000000a'
\set B '00000000-0000-0000-0000-00000000000b'
\set C '11111111-1111-1111-1111-111111111111'
\set K1 '0123456789abcdef0123456789abcdef'
\set K2 'fedcba9876543210fedcba9876543210'
create function pg_temp.expect(ok boolean, label text) returns void language plpgsql as
  $$ begin if not ok then raise exception 'ÉCHEC : %', label; end if; raise notice 'ok  %', label; end $$;

select pg_temp.expect((select count(*) from information_schema.columns where table_name = 'sync_courses' and column_name in ('name', 'code')) = 0, 'les colonnes en clair ont disparu');
select pg_temp.expect((select count(*) from information_schema.columns where table_name = 'sync_courses' and column_name in ('payload', 'key_id')) = 2, 'payload et key_id présents');

set role authenticated;
select set_config('request.jwt.claim.sub', :'A', false);

-- Sans coffre, aucune ligne : la clé doit être celle du coffre du compte.
do $$ begin
  insert into sync_courses (id, updated_at, payload, key_id) values (gen_random_uuid(), now(), '\x01'::bytea, '0123456789abcdef0123456789abcdef');
  raise exception 'ÉCHEC : ligne acceptée sans coffre';
exception when insufficient_privilege then raise notice 'ok  ligne refusée sans coffre';
end $$;
insert into sync_vault (key_id) values (:'K1');
insert into sync_courses (id, updated_at, payload, key_id) values (:'C', '2026-10-30T10:00:00Z', '\x0a0b'::bytea, :'K1');
-- Une clé d'avant une réinitialisation (pas celle du coffre) : refusée, même pour une ligne neuve.
do $$ begin
  insert into sync_courses (id, updated_at, payload, key_id) values (gen_random_uuid(), now(), '\x01'::bytea, 'fedcba9876543210fedcba9876543210');
  raise exception 'ÉCHEC : clé périmée acceptée';
exception when insufficient_privilege then raise notice 'ok  clé périmée refusée';
end $$;
select pg_temp.expect((select user_id from sync_courses where id = :'C') = :'A', 'user_id posé par défaut');

-- Une ligne vivante sans contenu n'a pas de sens ; une pierre tombale n'en a pas.
do $$ begin
  insert into sync_courses (id, updated_at, key_id) values ('22222222-2222-2222-2222-222222222222', now(), '0123456789abcdef0123456789abcdef');
  raise exception 'ÉCHEC : ligne vivante sans payload acceptée';
exception when check_violation then raise notice 'ok  ligne vivante sans payload refusée';
end $$;
insert into sync_courses (id, updated_at, deleted_at, key_id) values ('22222222-2222-2222-2222-222222222222', now(), now(), :'K1');
select pg_temp.expect((select payload is null from sync_courses where id = '22222222-2222-2222-2222-222222222222'), 'pierre tombale sans payload acceptée');
do $$ begin
  insert into sync_courses (id, updated_at, payload, key_id) values (gen_random_uuid(), now(), '\x01'::bytea, 'pas-un-identifiant');
  raise exception 'ÉCHEC : key_id mal formé accepté';
exception when check_violation or insufficient_privilege then raise notice 'ok  key_id mal formé refusé';
end $$;

create temp table t0 as select server_updated_at as s from sync_courses where id = :'C';
select pg_sleep(0.01);

-- Écriture plus récente : acceptée, curseur avancé.
update sync_courses set payload = '\x0c'::bytea, updated_at = '2026-10-30T11:00:00Z' where id = :'C';
select pg_temp.expect((select payload from sync_courses where id = :'C') = '\x0c'::bytea, 'écriture récente acceptée');
select pg_temp.expect((select server_updated_at from sync_courses where id = :'C') > (select s from t0), 'curseur serveur avancé');

-- Écriture plus ancienne (appareil resté hors ligne) : ignorée.
update sync_courses set payload = '\xdead'::bytea, updated_at = '2026-10-30T09:00:00Z' where id = :'C';
select pg_temp.expect((select payload from sync_courses where id = :'C') = '\x0c'::bytea, 'écriture périmée ignorée');

-- Upsert comme le feront les clients.
insert into sync_courses (id, updated_at, payload, key_id) values (:'C', '2026-10-30T08:00:00Z', '\xbad0'::bytea, :'K1')
  on conflict (id) do update set payload = excluded.payload, updated_at = excluded.updated_at, key_id = excluded.key_id;
select pg_temp.expect((select payload from sync_courses where id = :'C') = '\x0c'::bytea, 'upsert périmé ignoré');
insert into sync_courses (id, updated_at, payload, key_id) values (:'C', '2026-10-30T12:00:00Z', '\x0d'::bytea, :'K1')
  on conflict (id) do update set payload = excluded.payload, updated_at = excluded.updated_at, key_id = excluded.key_id;
select pg_temp.expect((select payload from sync_courses where id = :'C') = '\x0d'::bytea, 'upsert récent accepté');

-- Le client relit la version gardée dans la réponse (return=representation).
create temp table echo as with up as (
  insert into sync_courses (id, updated_at, payload, key_id) values (:'C', '2026-10-30T07:00:00Z', '\xbad1'::bytea, :'K1')
    on conflict (id) do update set payload = excluded.payload, updated_at = excluded.updated_at, key_id = excluded.key_id
    returning payload, updated_at)
  select * from up;
select pg_temp.expect((select payload from echo) = '\x0d'::bytea, 'envoi périmé : la réponse porte la version du serveur');

-- Une ligne ne change pas de clé : le serveur ne laisse pas écraser du contenu d'une autre clé.
do $$ begin
  insert into sync_courses (id, updated_at, payload, key_id) values ('11111111-1111-1111-1111-111111111111', '2026-10-30T13:30:00Z', '\x0e'::bytea, 'fedcba9876543210fedcba9876543210')
    on conflict (id) do update set payload = excluded.payload, updated_at = excluded.updated_at, key_id = excluded.key_id;
  raise exception 'ÉCHEC : changement de clé accepté';
exception when insufficient_privilege then raise notice 'ok  changement de clé refusé';
end $$;
select pg_temp.expect((select key_id from sync_courses where id = :'C') = :'K1', 'la clé de la ligne est intacte');

-- Pierre tombale.
update sync_courses set deleted_at = now(), payload = null, updated_at = '2026-10-30T13:00:00Z' where id = :'C';
select pg_temp.expect((select deleted_at is not null and payload is null from sync_courses where id = :'C'), 'pierre tombale enregistrée');

-- Changement de propriétaire refusé.
do $$ begin
  update sync_courses set user_id = '00000000-0000-0000-0000-00000000000b', updated_at = '2026-10-30T14:00:00Z'
    where id = '11111111-1111-1111-1111-111111111111';
  raise exception 'ÉCHEC : changement de propriétaire accepté';
exception when insufficient_privilege then raise notice 'ok  changement de propriétaire refusé';
end $$;

-- Le coffre : un par compte, écrit une fois (créé plus haut).
select pg_temp.expect((select user_id from sync_vault) = :'A', 'coffre : user_id posé par défaut');
do $$ begin
  insert into sync_vault (key_id) values ('fedcba9876543210fedcba9876543210');
  raise exception 'ÉCHEC : deuxième coffre accepté';
exception when unique_violation then raise notice 'ok  un seul coffre par compte';
end $$;
-- Aucune politique d'UPDATE : la mise à jour ne touche rien (et le déclencheur la refuserait même au rôle service).
update sync_vault set key_id = 'fedcba9876543210fedcba9876543210';
select pg_temp.expect((select key_id from sync_vault) = :'K1', 'coffre intact');

-- L'autre compte ne voit rien, ne peut ni écrire chez A ni usurper user_id.
select set_config('request.jwt.claim.sub', :'B', false);
select pg_temp.expect((select count(*) from sync_courses) = 0, 'RLS : B ne voit pas les lignes de A');
select pg_temp.expect((select count(*) from sync_vault) = 0, 'RLS : B ne voit pas le coffre de A');
update sync_courses set payload = '\xbad2'::bytea where id = :'C';
do $$ begin
  insert into sync_courses (id, user_id, updated_at, payload, key_id) values (gen_random_uuid(), '00000000-0000-0000-0000-00000000000a', now(), '\x01'::bytea, '0123456789abcdef0123456789abcdef');
  raise exception 'ÉCHEC : insertion au nom de A acceptée';
exception when insufficient_privilege then raise notice 'ok  RLS : B ne peut pas écrire au nom de A';
end $$;
do $$ begin
  insert into sync_vault (user_id, key_id) values ('00000000-0000-0000-0000-00000000000a', '0123456789abcdef0123456789abcdef');
  raise exception 'ÉCHEC : coffre au nom de A accepté';
exception when insufficient_privilege or unique_violation then raise notice 'ok  RLS : B ne peut pas écrire un coffre au nom de A';
end $$;
do $$ begin
  insert into sync_courses (id, updated_at, payload, key_id) values ('11111111-1111-1111-1111-111111111111', now(), '\x01'::bytea, '0123456789abcdef0123456789abcdef');
  raise exception 'ÉCHEC : collision d''identifiant acceptée';
exception when unique_violation or insufficient_privilege then raise notice 'ok  B ne peut pas reprendre un id de A';
end $$;
-- B a ses propres lignes et son coffre.
insert into sync_vault (key_id) values (:'K2');
insert into sync_courses (id, updated_at, payload, key_id) values ('33333333-3333-3333-3333-333333333333', now(), '\x01'::bytea, :'K2');
select set_config('request.jwt.claim.sub', :'A', false);
select pg_temp.expect((select payload from sync_courses where id = '11111111-1111-1111-1111-111111111111') is null, 'RLS : la ligne de A est intacte');

reset role;
do $$ begin
  update sync_vault set key_id = 'fedcba9876543210fedcba9876543210';
  raise exception 'ÉCHEC : coffre modifié par le rôle propriétaire';
exception when insufficient_privilege then raise notice 'ok  le coffre ne se modifie pas, même sans RLS';
end $$;
select pg_temp.expect((select count(*) from pg_publication_tables where pubname = 'supabase_realtime') = 15, 'les 15 tables sont publiées en temps réel');

-- Rejouable sans perte : une seconde application ne touche pas aux tables chiffrées.
\i :migration
select pg_temp.expect((select count(*) from sync_courses) = 3, 'rejeu : les lignes chiffrées sont toujours là');
select pg_temp.expect((select count(*) from sync_vault) = 2, 'rejeu : les coffres sont toujours là');

-- Réinitialiser le coffre : les lignes et le coffre de A partent, ceux de B restent.
set role authenticated;
select set_config('request.jwt.claim.sub', :'A', false);
select sync_reset_vault();
select pg_temp.expect((select count(*) from sync_courses) = 0, 'réinitialisation : les lignes de A sont effacées');
select pg_temp.expect((select count(*) from sync_vault) = 0, 'réinitialisation : le coffre de A est effacé');
insert into sync_vault (key_id) values (:'K2');
select pg_temp.expect((select key_id from sync_vault) = :'K2', 'après réinitialisation, un nouveau coffre peut être créé');
select set_config('request.jwt.claim.sub', :'B', false);
select pg_temp.expect((select count(*) from sync_courses) = 1, 'réinitialisation : les lignes de B restent');
select pg_temp.expect((select count(*) from sync_vault) = 1, 'réinitialisation : le coffre de B reste');
reset role;

-- Suppression du compte : tout part en cascade.
delete from auth.users where id = :'A';
select pg_temp.expect((select count(*) from sync_courses) = 1, 'suppression du compte : ses données seules sont supprimées');
select pg_temp.expect((select count(*) from sync_vault) = 1, 'suppression du compte : son coffre part');
SQL

echo "✅ migrations de synchronisation vérifiées"
