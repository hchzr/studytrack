#!/usr/bin/env bash
# « Continuer avec Apple » hors des appareils Apple (Windows) : Supabase passe alors par le
# flux web d'Apple, qui demande un **Services ID** et un secret signé par une clé « Sign in
# with Apple ». Ce script fabrique le secret (un JWT ES256, valable 6 mois au plus) et le
# pose dans Supabase, en gardant les identifiants déjà déclarés (l'app iPhone/Mac).
#
# À lancer dans un Terminal à toi (le jeton Supabase se tape à l'invite) :
#
#   supabase/setup-apple-web.sh ~/Downloads/AuthKey_XXXXXXXXXX.p8
#
# À refaire tous les 6 mois (le secret expire ; Apple n'en accepte pas de plus long).
set -euo pipefail

P8="${1:?Usage : $0 <chemin du fichier AuthKey_XXXXXXXXXX.p8>}"
[[ -f "$P8" ]] || { echo "Fichier introuvable : $P8" >&2; exit 1; }
TEAM_ID="${APPLE_TEAM_ID:-5GGDH5F3NG}"
SERVICES_ID="${APPLE_SERVICES_ID:-com.hczr.studytrack.web}"
# L'identifiant de la clé est dans le nom du fichier (AuthKey_<KEY_ID>.p8).
KEY_ID="${APPLE_KEY_ID:-$(basename "$P8" | sed -n 's/^AuthKey_\([A-Z0-9]*\)\.p8$/\1/p')}"
[[ -n "$KEY_ID" ]] || { echo "Identifiant de clé introuvable : passe APPLE_KEY_ID=…" >&2; exit 1; }
REF="$(cat "$(dirname "$0")/.temp/project-ref")"

if [[ -z "${SUPABASE_ACCESS_TOKEN:-}" ]]; then read -rsp "Jeton d'accès Supabase (sbp_…) : " SUPABASE_ACCESS_TOKEN; echo; fi
SUPABASE_ACCESS_TOKEN="$(tr -d '[:space:]' <<<"$SUPABASE_ACCESS_TOKEN")"
[[ "$SUPABASE_ACCESS_TOKEN" == sbp_* ]] || { echo "Ce n'est pas un jeton d'accès Supabase (sbp_…)." >&2; exit 1; }

# Le secret : JWT ES256 {iss: équipe, sub: Services ID, aud: appleid}, signé par la clé .p8.
SECRET="$(TEAM_ID="$TEAM_ID" KEY_ID="$KEY_ID" SERVICES_ID="$SERVICES_ID" P8="$P8" node -e '
const crypto = require("crypto"), fs = require("fs");
const b64 = (o) => Buffer.from(typeof o === "string" ? o : JSON.stringify(o)).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const head = b64({ alg: "ES256", kid: process.env.KEY_ID, typ: "JWT" });
const body = b64({ iss: process.env.TEAM_ID, iat: now, exp: now + 180 * 86400, aud: "https://appleid.apple.com", sub: process.env.SERVICES_ID });
const sig = crypto.sign("sha256", Buffer.from(head + "." + body), { key: fs.readFileSync(process.env.P8), dsaEncoding: "ieee-p1363" });
process.stdout.write(head + "." + body + "." + sig.toString("base64url"));
')"

api() { curl -sS -w '\n%{http_code}' -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H "Content-Type: application/json" "$@"; }
check() { local code="${1##*$'\n'}"; [[ "$code" == 2* ]] || { echo "Supabase a refusé ($code) : ${1%$'\n'*}" >&2; exit 1; }; }

current="$(api "https://api.supabase.com/v1/projects/$REF/config/auth")"; check "$current"
ids="$(jq -r '.external_apple_client_id // ""' <<<"${current%$'\n'*}")"
# Le Services ID d'abord (Supabase s'en sert pour le flux web), puis ceux de l'app (jetons natifs).
merged="$(printf '%s\n' "$SERVICES_ID" ${ids//,/ } | awk 'NF && !seen[$0]++' | paste -sd, -)"

answer="$(api -X PATCH "https://api.supabase.com/v1/projects/$REF/config/auth" \
  -d "$(jq -n --arg ids "$merged" --arg secret "$SECRET" '{external_apple_enabled: true, external_apple_client_id: $ids, external_apple_secret: $secret}')")"
check "$answer"
echo "Supabase : Apple sur le web activé (identifiants : $merged). Secret valable jusqu'au $(date -v+180d '+%d/%m/%Y')."
