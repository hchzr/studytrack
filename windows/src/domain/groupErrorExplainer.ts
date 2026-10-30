/// Traduit une erreur Supabase en une phrase actionnable.
///
/// Fonction **pure** : elle ne reçoit qu'une chaîne, donc elle se teste sur les
/// réponses réelles du serveur. C'est important : ce traducteur a déjà menti deux
/// fois — en annonçant « politiques RLS » sans dire quelle table, et en laissant
/// croire qu'un réexécutable du SQL suffisait. Un diagnostic qu'on ne peut pas
/// tester est un diagnostic qu'on devine.
export function explain(raw: string): string {
  const detail = serverDetail(raw);

  if (raw.includes("PGRST205")) {
    return "les tables n'existent pas encore côté Supabase. Exécute `Support/supabase-schema.sql` dans le SQL Editor, puis relance la synchronisation.";
  }
  if (raw.includes("PGRST202")) {
    return "la fonction `group_leaderboard` est absente. Elle est incluse dans `Support/supabase-schema.sql`.";
  }
  if (raw.includes("PGRST201")) {
    return "le serveur trouve deux chemins entre deux tables et refuse de choisir. Relance `Support/supabase-schema.sql` : les clés étrangères y sont explicites.";
  }
  if (raw.includes("permission denied")) {
    // 42501 sur une **lecture** : ce n'est pas une politique RLS — elle
    // filtrerait en silence — mais un droit de table manquant.
    return `le serveur refuse l'accès à la table (droits manquants). Réexécute \`Support/supabase-schema.sql\` : il accorde explicitement les droits aux rôles de l'app.${detail}`;
  }
  if (raw.includes("42501") || raw.includes("row-level security")) {
    return `les politiques RLS refusent cette écriture — le plus souvent parce que tu n'es pas membre du groupe côté serveur. Appuie sur « Réparer et réessayer » : la synchronisation rétablit ton adhésion si tu as créé le groupe.${detail}`;
  }
  if (raw.includes("23503")) {
    return `le profil n'existe pas encore côté serveur. Reconnecte-toi, puis relance.${detail}`;
  }
  if (raw.includes("23505")) {
    return `cette ligne existe déjà côté serveur.${detail}`;
  }
  return raw;
}

const trimmed = (value: unknown): string | undefined =>
  typeof value === "string" ? value.trim() : undefined;

/// Extrait le message Postgres de la réponse JSON, pour l'ajouter au texte.
///
/// PostgREST renvoie `{"code":"42501","message":"new row violates row-level
/// security policy for table \"presence\"","details":null}`. Le `message` nomme
/// la table et l'opération ; sans lui, l'utilisateur — et moi — devinons.
/// Renvoie une chaîne vide s'il n'y a rien à ajouter : jamais de « Serveur : »
/// orphelin.
export function serverDetail(raw: string): string {
  const start = raw.indexOf("{");
  if (start < 0) return "";
  let object: unknown;
  try {
    object = JSON.parse(raw.slice(start));
  } catch {
    return "";
  }
  if (object === null || typeof object !== "object" || Array.isArray(object)) return "";
  const dict = object as Record<string, unknown>;
  const message = trimmed(dict.message);
  const code = trimmed(dict.code) || undefined;
  const hint = trimmed(dict.hint) || undefined;

  const parts: string[] = [];
  if (message) parts.push(message);
  if (hint) parts.push(hint);
  if (code) parts.push(`code ${code}`);
  return parts.length === 0 ? "" : "\n\nServeur : " + parts.join(" · ");
}

export const GroupErrorExplainer = { explain, serverDetail };
