// La configuration Supabase de ce build — le pendant Windows de
// `Support/Supabase.xcconfig` : côté Apple l'URL et la clé anon sont compilées
// dans l'app, ici elles arrivent par l'environnement Vite (`windows/.env`,
// documenté par `.env.example`).
//
// Absente est un état **valide** : l'app fonctionne entièrement hors ligne, et
// l'écran Réglages dit simplement que la synchronisation n'est pas configurée.
// La clé anon est publique par conception (les politiques RLS protègent les
// données) ; la clé service_role, elle, ne doit jamais arriver jusqu'ici.

export interface SupabaseConfig {
  /** Racine du projet, « https://…supabase.co ». */
  url: string;
  /** La clé publique « anon » du projet. */
  anonKey: string;
}

/** La configuration du build ; `null` quand ce build n'en embarque pas. */
export function supabaseConfig(): SupabaseConfig | null {
  const url = (import.meta.env.VITE_SUPABASE_URL ?? "").trim();
  const anonKey = (import.meta.env.VITE_SUPABASE_ANON_KEY ?? "").trim();
  if (url === "" || anonKey === "") return null;
  return { url, anonKey };
}

/**
 * L'hôte du relais (Cloudflare Worker, dossier relay/), sans « https:// » :
 * l'appairage d'un appareil y passe par une WebSocket « wss://<hôte>/v1/pair-… ».
 * Le pendant du réglage `TIMER_RELAY_HOST` des apps Apple. `null` : pas
 * d'appairage possible dans ce build (la clé de secours reste).
 */
export function relayHost(): string | null {
  const host = (import.meta.env.VITE_RELAY_HOST ?? "").trim().replace(/^https?:\/\//, "").replace(/\/+$/, "");
  return host === "" ? null : host;
}
