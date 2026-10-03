-- Le coût réel de chaque appel à un modèle (analyze-course, extract-series) :
-- jetons, coût annoncé par le fournisseur (OpenRouter), durée. Pour estimer la
-- facture par utilisateur et comparer les modèles sur l'usage réel. Seul le
-- rôle de service (les fonctions) y écrit ; aucune donnée personnelle.

create table if not exists public.ai_usage (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  function text not null,
  provider text,
  model text,
  prompt_tokens integer,
  completion_tokens integer,
  cached_tokens integer,
  reasoning_tokens integer,
  cost numeric,
  ms integer,
  evaluation boolean not null default false
);

create index if not exists ai_usage_created_at on public.ai_usage (created_at desc);
alter table public.ai_usage enable row level security;
