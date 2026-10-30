#!/usr/bin/env bash
#
# Tableau de bord des jobs `dsh headless` lancés pour le portage.
#
# Chaque job écrit son raisonnement sur stderr (jobN.err) et son rapport final
# sur stdout (jobN.out, vide tant qu'il n'a pas fini).
#
#   windows/scripts/dsh-monitor.sh            # tableau rafraîchi toutes les 5 s
#   windows/scripts/dsh-monitor.sh -f         # flux brut des quatre jobs (tail -f)
#   windows/scripts/dsh-monitor.sh -n 20      # 20 lignes par job au lieu de 6
#   DSH_JOBS=/autre/dossier windows/scripts/dsh-monitor.sh

JOBS="${DSH_JOBS:-/private/tmp/claude-501/-Users-hczr-Prog-M-Connect/1758a4e0-a0dd-4431-ab9d-103f9d1d34d5/scratchpad/dsh}"
WINDOWS="$(cd "$(dirname "$0")/.." && pwd)"
LINES=6
FOLLOW=0
while [ $# -gt 0 ]; do
  case "$1" in
    -f) FOLLOW=1 ;;
    -n) shift; LINES="$1" ;;
    *) echo "usage: $0 [-f] [-n lignes]"; exit 1 ;;
  esac
  shift
done

if [ "$FOLLOW" = 1 ]; then
  exec tail -n 20 -f "$JOBS"/job*.err
fi

titles=("" "Moodle et import de contenu" "Séries et PDF" "Mode étude, moteurs, doublons" "Recherche, carte, Claude")
bold=$'\e[1m'; dim=$'\e[2m'; green=$'\e[32m'; yellow=$'\e[33m'; red=$'\e[31m'; reset=$'\e[0m'

status() {
  local n="$1" err="$JOBS/job$n.err" out="$JOBS/job$n.out"
  # Le processus vivant est celui qui tient le fichier stderr ouvert.
  if lsof -t "$err" >/dev/null 2>&1; then
    local age=$(( $(date +%s) - $(stat -f %m "$err") ))
    if [ "$age" -gt 300 ]; then echo "${yellow}en cours, muet depuis ${age}s${reset}"
    else echo "${green}en cours${reset} ${dim}(dernière sortie il y a ${age}s)${reset}"; fi
  elif [ -s "$out" ]; then echo "${bold}terminé${reset} ${dim}(rapport : $out)${reset}"
  else echo "${red}arrêté sans rapport${reset}"; fi
}

while true; do
  clear
  echo "${bold}Jobs dsh${reset} ${dim}— $(date '+%H:%M:%S') — Ctrl-C pour quitter, -f pour le flux brut${reset}"
  for n in 1 2 3 4; do
    [ -f "$JOBS/job$n.err" ] || continue
    echo
    echo "${bold}job$n · ${titles[$n]}${reset} — $(status "$n")"
    grep -v '^[[:space:]]*$' "$JOBS/job$n.err" | tail -n "$LINES" | cut -c1-"${COLUMNS:-160}" | sed 's/^/  /'
  done
  echo
  echo "${bold}Fichiers écrits depuis le lancement${reset}"
  (cd "$WINDOWS" && find src tests -newer PORTING.md -type f 2>/dev/null | sort | sed 's/^/  /')
  sleep 5
done
