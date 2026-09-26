-- Suppression du compte depuis l'app (exigence App Store 5.1.1(v)).
--
-- L'utilisateur·rice connecté·e supprime **son propre** compte : la ligne
-- `auth.users` part, et tout ce qui en dépend suit par cascade (profil,
-- adhésions, temps publié, avancement, présence, XP).
--
-- Deux références ne cascadent pas : `study_groups.created_by` et
-- `planned_sessions.created_by`. Elles sont remises à `null` d'abord — le groupe
-- et ses sessions restent aux autres membres, sans auteur — sinon la suppression
-- échouerait sur une violation de clé étrangère.
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'non authentifié' using errcode = '28000';
  end if;
  update public.study_groups set created_by = null where created_by = me;
  update public.planned_sessions set created_by = null where created_by = me;
  delete from auth.users where id = me;
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

notify pgrst, 'reload schema';
