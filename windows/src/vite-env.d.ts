/// <reference types="vite/client" />

// Les valeurs de déploiement Supabase (voir services/syncConfig.ts). Elles
// viennent de `windows/.env` — jamais du dépôt : `Support/Supabase.xcconfig`
// garde les valeurs réelles côté Apple, `.env.example` documente les noms.
interface ImportMetaEnv {
  /** Racine du projet Supabase, « https://…supabase.co ». */
  readonly VITE_SUPABASE_URL?: string;
  readonly VITE_RELAY_HOST?: string;
  /** L'app Spotify (developer.spotify.com), pour Spotify Connect. */
  readonly VITE_SPOTIFY_CLIENT_ID?: string;
  /** La clé publique « anon » du projet — jamais la clé service_role. */
  readonly VITE_SUPABASE_ANON_KEY?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
