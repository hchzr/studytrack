#!/usr/bin/env bash
# Branche Resend comme serveur d'envoi des e-mails de Supabase (confirmation d'inscription,
# mot de passe oublié…) et met le code à 6 chiffres dans le message de confirmation.
#
# À lancer dans un Terminal à toi : les deux clés se tapent à l'invite, sans s'afficher,
# et ne sont écrites nulle part (ni fichier, ni historique, ni conversation).
#
#   supabase/setup-email.sh
#
# Ce qu'il faut :
#   - une clé API Resend « Full access » (resend.com › API Keys) ;
#   - un jeton d'accès Supabase (supabase.com › Account › Access Tokens).
#
# Idempotent : relançable autant de fois que nécessaire (par ex. après avoir posé le DNS).
set -euo pipefail

DOMAIN="${EMAIL_DOMAIN:-studytrack.hczr.ch}"
SENDER="${EMAIL_SENDER:-noreply@$DOMAIN}"
REF="$(cat "$(dirname "$0")/.temp/project-ref")"

need() { command -v "$1" >/dev/null || { echo "Il manque « $1 »." >&2; exit 1; }; }
need curl
need jq

if [[ -z "${RESEND_API_KEY:-}" ]]; then read -rsp "Clé API Resend (re_…) : " RESEND_API_KEY; echo; fi
if [[ -z "${SUPABASE_ACCESS_TOKEN:-}" ]]; then read -rsp "Jeton d'accès Supabase (sbp_…) : " SUPABASE_ACCESS_TOKEN; echo; fi

resend() { curl -sS -H "Authorization: Bearer $RESEND_API_KEY" -H "Content-Type: application/json" "$@"; }

# 1. Le domaine d'envoi chez Resend (créé s'il n'existe pas).
domains="$(resend https://api.resend.com/domains)"
if [[ "$(jq -r '.statusCode? // empty' <<<"$domains")" != "" ]]; then
  echo "Resend refuse la clé : $(jq -r .message <<<"$domains")" >&2
  echo "Il faut une clé « Full access » (pas « Sending access »)." >&2
  exit 1
fi
id="$(jq -r --arg d "$DOMAIN" '.data[] | select(.name == $d) | .id' <<<"$domains" | head -1)"
if [[ -z "$id" ]]; then
  echo "Ajout de $DOMAIN chez Resend…"
  id="$(resend -X POST https://api.resend.com/domains -d "$(jq -n --arg d "$DOMAIN" '{name: $d, region: "eu-west-1"}')" | jq -r .id)"
fi
resend -X POST "https://api.resend.com/domains/$id/verify" >/dev/null || true
domain="$(resend "https://api.resend.com/domains/$id")"
status="$(jq -r .status <<<"$domain")"
echo "Domaine $DOMAIN chez Resend : $status"
if [[ "$status" != "verified" ]]; then
  echo
  echo "À poser dans Cloudflare (zone hczr.ch › DNS › Records), proxy désactivé (nuage gris) :"
  jq -r '.records[] | "  \(.record // .type)\t\(.type)\t\(.name)\t\(.value)\(if .priority then "\tpriorité \(.priority)" else "" end)"' <<<"$domain"
  echo
  echo "(Ou, plus simple : sur resend.com › Domains › $DOMAIN, le bouton « Auto configure » avec Cloudflare.)"
  echo "Les e-mails partiront dès que Resend aura vu ces enregistrements (quelques minutes)."
fi

# 2. Supabase : le serveur d'envoi, l'expéditeur, et le message de confirmation avec le code.
read -r -d '' TEMPLATE <<'HTML' || true
<div style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;max-width:440px;margin:0 auto;padding:24px;color:#1c1c1e">
  <h2 style="font-weight:600;margin:0 0 12px">Bienvenue sur StudyTrack</h2>
  <p style="margin:0 0 16px">Ton code de confirmation :</p>
  <p style="font-size:32px;letter-spacing:8px;font-weight:700;margin:0 0 16px;font-family:SFMono-Regular,Consolas,monospace">{{ .Token }}</p>
  <p style="margin:0 0 16px">Tape-le dans l'app. Il est valable une heure.</p>
  <p style="margin:0 0 24px;color:#6e6e73;font-size:13px">Ou confirme d'un clic : <a href="{{ .ConfirmationURL }}">confirmer mon adresse</a>.</p>
  <p style="margin:0;color:#8e8e93;font-size:12px">Tu n'as pas créé de compte StudyTrack ? Ignore ce message.</p>
</div>
HTML

body="$(jq -n \
  --arg pass "$RESEND_API_KEY" \
  --arg admin "$SENDER" \
  --arg tpl "$TEMPLATE" \
  '{
    external_email_enabled: true,
    mailer_autoconfirm: false,
    smtp_host: "smtp.resend.com",
    smtp_port: "465",
    smtp_user: "resend",
    smtp_pass: $pass,
    smtp_admin_email: $admin,
    smtp_sender_name: "StudyTrack",
    smtp_max_frequency: 60,
    rate_limit_email_sent: 60,
    mailer_otp_exp: 3600,
    mailer_subjects_confirmation: "Ton code StudyTrack",
    mailer_templates_confirmation_content: $tpl
  }')"

answer="$(curl -sS -w '\n%{http_code}' -X PATCH "https://api.supabase.com/v1/projects/$REF/config/auth" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H "Content-Type: application/json" -d "$body")"
code="${answer##*$'\n'}"
if [[ "$code" != "200" ]]; then
  echo "Supabase a refusé ($code) : ${answer%$'\n'*}" >&2
  exit 1
fi
echo "Supabase : envoi par Resend ($SENDER), message de confirmation avec le code — fait."
