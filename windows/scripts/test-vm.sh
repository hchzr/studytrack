#!/usr/bin/env bash
# Une machine Windows de test sur AWS (EC2), à la demande, et la connexion Bureau à distance.
#
#   windows/scripts/test-vm.sh up      # crée (ou rallume) la machine et ouvre la connexion
#   windows/scripts/test-vm.sh connect # rouvre la connexion (mot de passe copié dans le presse-papiers)
#   windows/scripts/test-vm.sh stop    # l'éteint : plus de calcul facturé, le disque reste (~3 $/mois)
#   windows/scripts/test-vm.sh down    # la détruit, avec sa clé et son pare-feu : plus rien de facturé
#   windows/scripts/test-vm.sh status
#
# Windows Server 2025 (bureau complet, Edge et WebView2 inclus), t3.large (2 cœurs, 8 Go).
# Le Bureau à distance (port 3389) n'est ouvert qu'à l'adresse IP publique de ce Mac.
# Prérequis : `aws login` (ou `aws configure`) fait une fois, et l'app « Windows App ».
set -euo pipefail

REGION="${AWS_REGION:-${STUDYTRACK_VM_REGION:-eu-central-1}}" # Francfort : proche, et activée sur tout compte (Zurich est en option)
TYPE="${STUDYTRACK_VM_TYPE:-t3.large}"
NAME="studytrack-windows-test"
KEY_FILE="$HOME/.ssh/$NAME.pem"
RDP_FILE="$HOME/Downloads/$NAME.rdp"
export AWS_REGION="$REGION" AWS_PAGER=""

aws sts get-caller-identity >/dev/null 2>&1 || {
  echo "AWS n'est pas connecté : lance « aws login » (ou « aws configure ») d'abord." >&2
  exit 1
}

instance_id() {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text | awk '{print $1}'
}

my_ip() { curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]'; }

security_group() {
  local sg
  sg="$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$NAME" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
  if [[ -z "$sg" || "$sg" == "None" ]]; then
    sg="$(aws ec2 create-security-group --group-name "$NAME" \
      --description "StudyTrack Windows test VM: RDP from one IP" --query GroupId --output text)"
  fi
  # Le Bureau à distance depuis l'adresse actuelle seulement (elle change : on la remet à chaque fois).
  local ip; ip="$(my_ip)"
  aws ec2 authorize-security-group-ingress --group-id "$sg" \
    --ip-permissions "IpProtocol=tcp,FromPort=3389,ToPort=3389,IpRanges=[{CidrIp=$ip/32,Description=mac}]" \
    >/dev/null 2>&1 || true
  # UDP aussi : le Bureau à distance y passe l'image (plus fluide, plus net qu'en TCP seul).
  aws ec2 authorize-security-group-ingress --group-id "$sg" \
    --ip-permissions "IpProtocol=udp,FromPort=3389,ToPort=3389,IpRanges=[{CidrIp=$ip/32,Description=mac}]" \
    >/dev/null 2>&1 || true
  echo "$sg"
}

key_pair() {
  if [[ ! -f "$KEY_FILE" ]]; then
    aws ec2 delete-key-pair --key-name "$NAME" >/dev/null 2>&1 || true
    mkdir -p "$(dirname "$KEY_FILE")"
    aws ec2 create-key-pair --key-name "$NAME" --key-type rsa --key-format pem \
      --query KeyMaterial --output text >"$KEY_FILE"
    chmod 600 "$KEY_FILE"
  fi
}

public_ip() {
  aws ec2 describe-instances --instance-ids "$1" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}

password() {
  local id="$1" pw=""
  echo "Mot de passe Administrator : Windows le génère au premier démarrage (4 à 8 minutes)…" >&2
  for _ in $(seq 1 60); do
    pw="$(aws ec2 get-password-data --instance-id "$id" --priv-launch-key "$KEY_FILE" \
      --query PasswordData --output text 2>/dev/null || true)"
    [[ -n "$pw" && "$pw" != "None" ]] && break
    sleep 15
  done
  [[ -n "$pw" && "$pw" != "None" ]] || { echo "Pas encore de mot de passe : relance « connect » dans quelques minutes." >&2; exit 1; }
  echo "$pw"
}

connect() {
  local id; id="$(instance_id)"
  [[ -n "$id" ]] || { echo "Aucune machine : lance « up »." >&2; exit 1; }
  security_group >/dev/null # l'IP du Mac a pu changer
  local ip; ip="$(public_ip "$id")"
  local pw; pw="$(password "$id")"
  cat >"$RDP_FILE" <<RDP
full address:s:$ip:3389
username:s:Administrator
prompt for credentials:i:0
screen mode id:i:2
dynamic resolution:i:1
session bpp:i:32
connection type:i:6
networkautodetect:i:1
bandwidthautodetect:i:1
redirectclipboard:i:1
drivestoredirect:s:*
keyboardhook:i:1
audiomode:i:0
RDP
  printf '%s' "$pw" | pbcopy
  echo "Machine : $ip — utilisateur Administrator, mot de passe copié dans le presse-papiers (⌘V à l'invite)."
  echo "Fichier de connexion : $RDP_FILE"
  open "$RDP_FILE"
}

case "${1:-status}" in
  up)
    id="$(instance_id)"
    if [[ -z "$id" ]]; then
      key_pair
      sg="$(security_group)"
      ami="$(aws ssm get-parameter --name /aws/service/ami-windows-latest/Windows_Server-2025-English-Full-Base \
        --query Parameter.Value --output text)"
      echo "Création de la machine ($TYPE, $REGION)…"
      id="$(aws ec2 run-instances --image-id "$ami" --instance-type "$TYPE" --key-name "$NAME" \
        --security-group-ids "$sg" \
        --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=50,VolumeType=gp3,DeleteOnTermination=true}' \
        --metadata-options HttpTokens=required \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
        --query 'Instances[0].InstanceId' --output text)"
    elif [[ "$(aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name' --output text)" != "running" ]]; then
      echo "Rallumage de $id…"
      aws ec2 wait instance-stopped --instance-ids "$id" 2>/dev/null || true
      aws ec2 start-instances --instance-ids "$id" >/dev/null
    fi
    aws ec2 wait instance-running --instance-ids "$id"
    echo "Machine $id allumée."
    connect
    ;;
  connect) connect ;;
  stop)
    id="$(instance_id)"; [[ -n "$id" ]] || { echo "Aucune machine."; exit 0; }
    aws ec2 stop-instances --instance-ids "$id" >/dev/null
    echo "Machine $id en cours d'extinction (le disque est gardé)."
    ;;
  down)
    id="$(instance_id)"
    if [[ -n "$id" ]]; then
      aws ec2 terminate-instances --instance-ids "$id" >/dev/null
      echo "Destruction de $id…"
      aws ec2 wait instance-terminated --instance-ids "$id"
    fi
    aws ec2 delete-security-group --group-name "$NAME" >/dev/null 2>&1 || true
    aws ec2 delete-key-pair --key-name "$NAME" >/dev/null 2>&1 || true
    rm -f "$KEY_FILE" "$RDP_FILE"
    echo "Plus rien sur AWS pour $NAME."
    ;;
  status)
    aws ec2 describe-instances --filters "Name=tag:Name,Values=$NAME" \
      --query 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType,PublicIpAddress]' --output table
    ;;
  *) echo "Usage : $0 up|connect|stop|down|status" >&2; exit 2 ;;
esac
