-- Limites d'appel des fonctions qui consomment des crédits de modèle
-- (analyze-course, extract-series) : un compteur par seau et par fenêtre.
-- Seul le rôle de service (les fonctions) y touche.

create table if not exists public.function_rate_limits (
  bucket text not null,
  window_start timestamptz not null,
  hits integer not null default 0,
  primary key (bucket, window_start)
);

alter table public.function_rate_limits enable row level security;

create or replace function public.hit_rate_limit(p_bucket text, p_window_seconds integer, p_max integer)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_window timestamptz := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  v_hits integer;
begin
  insert into public.function_rate_limits (bucket, window_start, hits)
  values (p_bucket, v_window, 1)
  on conflict (bucket, window_start) do update set hits = function_rate_limits.hits + 1
  returning hits into v_hits;
  -- Ménage : les fenêtres de plus de deux jours.
  if random() < 0.02 then
    delete from public.function_rate_limits where window_start < now() - interval '2 days';
  end if;
  return v_hits <= p_max;
end;
$$;

revoke all on function public.hit_rate_limit(text, integer, integer) from public, anon, authenticated;
grant execute on function public.hit_rate_limit(text, integer, integer) to service_role;
