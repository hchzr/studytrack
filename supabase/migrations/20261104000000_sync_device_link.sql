-- Le lien entre les appareils d'un compte (le chrono relié) : une ligne par compte, **chiffrée**
-- avec la clé de données de la synchronisation (comme les lignes `sync_*`), que le serveur ne
-- peut pas lire. Elle porte l'identité qui donne son canal au chrono relié : sur l'iPhone et le
-- Mac, elle vient d'iCloud ; Windows n'a pas iCloud et la lit ici, déchiffrée avec la clé du
-- compte qu'il a reçue à l'appairage. Le canal et la clé du chrono s'en déduisent sur l'appareil.
--
-- La ligne doit être écrite avec la clé en cours (`key_id` du coffre) : une clé périmée est refusée.

create table if not exists public.sync_device_link (
  user_id    uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  key_id     text not null check (key_id ~ '^[0-9a-f]{32}$'),
  payload    bytea not null check (octet_length(payload) between 29 and 4096),
  updated_at timestamptz not null default now()
);

alter table public.sync_device_link enable row level security;

drop policy if exists sync_device_link_select on public.sync_device_link;
create policy sync_device_link_select on public.sync_device_link for select using (user_id = auth.uid());
drop policy if exists sync_device_link_insert on public.sync_device_link;
create policy sync_device_link_insert on public.sync_device_link for insert with check (user_id = auth.uid());
drop policy if exists sync_device_link_update on public.sync_device_link;
create policy sync_device_link_update on public.sync_device_link for update using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists sync_device_link_delete on public.sync_device_link;
create policy sync_device_link_delete on public.sync_device_link for delete using (user_id = auth.uid());

create or replace function public.sync_device_link_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.sync_vault v where v.user_id = new.user_id and v.key_id = new.key_id) then
    raise exception 'clé périmée : ajoute de nouveau cet appareil' using errcode = '42501';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists sync_device_link_guard on public.sync_device_link;
create trigger sync_device_link_guard before insert or update on public.sync_device_link
  for each row execute function public.sync_device_link_guard();

-- Réinitialiser le coffre efface aussi le lien (il était chiffré avec l'ancienne clé).
create or replace function public.sync_device_link_on_vault_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.sync_device_link where user_id = old.user_id;
  return old;
end;
$$;

drop trigger if exists sync_device_link_on_vault_delete on public.sync_vault;
create trigger sync_device_link_on_vault_delete after delete on public.sync_vault
  for each row execute function public.sync_device_link_on_vault_delete();
