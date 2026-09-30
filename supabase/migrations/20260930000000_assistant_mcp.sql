-- Serveur MCP de StudyTrack : l'instantané que l'app publie pour un assistant,
-- et les modifications que l'assistant demande en retour.
--
-- Aucune politique RLS : seules la fonction `mcp` (clé de service) lit et écrit
-- ces tables. Un client avec la clé anonyme n'y voit rien. Le jeton de
-- l'utilisateur n'est jamais stocké, seulement son SHA-256.

create table if not exists public.assistant_links (
  token_hash   text primary key,
  snapshot     jsonb,
  snapshot_at  timestamptz,
  created_at   timestamptz not null default now(),
  last_used_at timestamptz
);

create table if not exists public.assistant_commands (
  id         uuid primary key default gen_random_uuid(),
  token_hash text not null references public.assistant_links(token_hash) on delete cascade,
  kind       text not null,
  payload    jsonb not null default '{}'::jsonb,
  summary    text,
  status     text not null default 'pending' check (status in ('pending', 'applied', 'failed')),
  result     text,
  created_at timestamptz not null default now(),
  applied_at timestamptz
);

create index if not exists assistant_commands_pending
  on public.assistant_commands (token_hash, status, created_at);

alter table public.assistant_links enable row level security;
alter table public.assistant_commands enable row level security;
