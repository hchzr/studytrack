#!/usr/bin/env bash
# StudyTrack → Polymestre : ce qui doit être en ligne AVANT la première build Polymestre.
# Tout est additif : les apps déjà installées continuent de marcher.
#
#   scripts/rename-deploy.sh
#
# - fonctions Supabase (en-tête, consignes du tuteur, retour OAuth, serveur MCP : ancien et nouveau) ;
# - réglages d'authentification Supabase : ajoute polymestre://auth-callback et ch.polymestre.app
#   à côté des valeurs actuelles ;
# - relais du chrono : push par app, et l'adresse relay.polymestre.ch.
#
# Il faut : ~/.config/polymestre/supabase (jeton sbp_…), wrangler connecté, jq.
set -euo pipefail
cd "$(dirname "$0")/.."

export SUPABASE_ACCESS_TOKEN="$(cat "$HOME/.config/polymestre/supabase")"
REF="$(cat supabase/.temp/project-ref)"

for f in extract-series analyze-course tutor; do
  supabase functions deploy "$f" --project-ref "$REF" --use-api
done
# Ces deux-là sont publiques (jeton propre pour l'une, retour de navigateur pour l'autre).
for f in mcp oauth; do
  supabase functions deploy "$f" --project-ref "$REF" --use-api --no-verify-jwt
done

api="https://api.supabase.com/v1/projects/$REF/config/auth"
auth=(-H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H "Content-Type: application/json")
current="$(curl -sS "${auth[@]}" "$api")"
add() { # liste séparée par des virgules, valeur
  case ",$1," in *",$2,"*) printf %s "$1" ;; *) printf %s "$1,$2" ;; esac
}
uris="$(add "$(jq -r .uri_allow_list <<<"$current")" "polymestre://auth-callback")"
apple="$(add "$(jq -r .external_apple_client_id <<<"$current")" "ch.polymestre.app")"
curl -sS -X PATCH "${auth[@]}" "$api" \
  -d "$(jq -n --arg u "$uris" --arg a "$apple" '{uri_allow_list: $u, external_apple_client_id: $a}')" \
  | jq '{uri_allow_list, external_apple_client_id}'

(cd relay && npx wrangler deploy)

echo "→ relais : $(curl -sS --retry 5 --retry-delay 5 --retry-all-errors https://relay.polymestre.ch/health) (nouvelle adresse)"
echo "→ relais : $(curl -sS https://studytrack-relay.apnsprobe.workers.dev/health) (ancienne adresse)"
