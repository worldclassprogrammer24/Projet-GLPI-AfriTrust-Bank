#!/usr/bin/env bash
# =============================================================================
# deploy_glpi_agent.sh : déploiement automatisé de GLPI Agent (Debian/Ubuntu)
# AfriTrust Bank - Lot 3
#
# Usage : sudo ./deploy_glpi_agent.sh [--glpi-ip IP] [--source URL] [--tag TAG] [--force]
#
#   --glpi-ip  IP du serveur GLPI de ce sous-réseau (défaut : 192.168.<site>.10, déduite)
#   --source   dépôt de déploiement (défaut : http://<glpi-ip>:8000)
#   --tag      impose le TAG (défaut : /etc/agence.conf, puis nom d'hôte, puis sous-réseau)
#   --force    réinstalle même si l'agent est déjà installé et à jour
#
# Codes de sortie : 0 OK | 1 droits/arguments | 2 réseau | 3 téléchargement
#                   4 installation | 5 service inactif | 6 OS non supporté
# =============================================================================
set -euo pipefail

LOG_FILE="/var/log/glpi_deploy.log"
BASE_DIR="/etc/afritrust"
CERT_FILE="$BASE_DIR/glpi.crt"
AGENT_LOG_DIR="/var/log/glpi-agent"
GLPI_IP=""; SOURCE=""; TAG=""; FORCE=0

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" | tee -a "$LOG_FILE"; }
usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

# --- Arguments ----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --glpi-ip) GLPI_IP="${2:-}"; shift 2 ;;
        --source)  SOURCE="${2:-}";  shift 2 ;;
        --tag)     TAG="${2:-}";     shift 2 ;;
        --force)   FORCE=1;          shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Option inconnue : $1" >&2; usage; exit 1 ;;
    esac
done

# --- 1. Privilèges root et OS -------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "Ce script doit être exécuté en root (sudo)." >&2
    exit 1
fi
mkdir -p "$(dirname "$LOG_FILE")"; touch "$LOG_FILE"

# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-} ${ID_LIKE:-}" in
    *debian*|*ubuntu*) ;;
    *) log ERROR "OS non supporté (Debian/Ubuntu requis) : ${PRETTY_NAME:-inconnu}"; exit 6 ;;
esac
log INFO "===== Début du déploiement GLPI Agent sur $(hostname) (${PRETTY_NAME:-}) ====="

# --- 2. Détermination du TAG et de l'IP du serveur ---------------------------
# 3e octet de la première IP appartenant à l'un des 4 sous-réseaux du projet
OCTET=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 \
        | grep -E '^192\.168\.(10|20|30|40)\.' | head -n1 | cut -d. -f3 || true)

if [[ -z "$TAG" && -f /etc/agence.conf ]]; then
    TAG=$(grep -E '^TAG=' /etc/agence.conf | head -n1 | cut -d= -f2- | tr -d '"' || true)
fi
if [[ -z "$TAG" ]]; then
    case "$(hostname | tr '[:lower:]' '[:upper:]')" in
        AG-DLA-*) TAG="AGENCE_DLA" ;;
        AG-YDE-*) TAG="AGENCE_YDE" ;;
        AG-BAF-*) TAG="AGENCE_BAF" ;;
        SIEGE-*)  TAG="SIEGE" ;;
        *)
            case "$OCTET" in
                10) TAG="SIEGE" ;;
                20) TAG="AGENCE_DLA" ;;
                30) TAG="AGENCE_YDE" ;;
                40) TAG="AGENCE_BAF" ;;
                *)  TAG="NON_CLASSE" ;;
            esac ;;
    esac
fi
log INFO "TAG : $TAG"
[[ "$TAG" == "NON_CLASSE" ]] && log WARN "Agence non reconnue : la machine restera dans l'entité racine"

if [[ -z "$GLPI_IP" ]]; then
    [[ -n "$OCTET" ]] || { log ERROR "IP du serveur GLPI introuvable : utiliser --glpi-ip"; exit 2; }
    GLPI_IP="192.168.${OCTET}.10"
fi
[[ -n "$SOURCE" ]] || SOURCE="http://${GLPI_IP}:8000"
GLPI_URL="https://${GLPI_IP}/"
log INFO "Serveur GLPI : $GLPI_URL | Dépôt : $SOURCE"

# --- 3. Connectivité avant toute action --------------------------------------
if ! curl -ks --max-time 10 -o /dev/null "$GLPI_URL"; then
    log ERROR "Serveur GLPI injoignable : $GLPI_URL"
    exit 2
fi

# --- Idempotence : agent actif et à jour -> rien à faire ---------------------
norm() { awk -F. '{printf "%d.%d.%d", $1+0, $2+0, $3+0}'; }
if systemctl is-active --quiet glpi-agent 2>/dev/null && [[ $FORCE -eq 0 ]]; then
    INSTALLED=$(glpi-agent --version 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)
    REPO_VER=$(curl -fs --max-time 15 "$SOURCE/version.txt" | tr -d '[:space:]' || true)
    if [[ -z "$REPO_VER" || -z "$INSTALLED" ]] \
       || [[ "$(printf '%s\n%s\n' "$(echo "$REPO_VER" | norm)" "$(echo "$INSTALLED" | norm)" | sort -V | tail -n1)" == "$(echo "$INSTALLED" | norm)" ]]; then
        log INFO "Agent déjà installé (${INSTALLED:-?}) et actif : rien à faire."
        exit 0
    fi
    log INFO "Mise à jour : $INSTALLED -> $REPO_VER"
fi

# --- 4. Téléchargement de l'installeur Perl et du certificat -----------------
WORK_DIR="$(mktemp -d /tmp/glpi-deploy.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$BASE_DIR"

log INFO "Téléchargement depuis $SOURCE"
curl -fsS --max-time 120 -o "$WORK_DIR/installer.pl" "$SOURCE/glpi-agent-installer.pl" \
    || { log ERROR "Échec du téléchargement de l'installeur"; exit 3; }
curl -fsS --max-time 30 -o "$CERT_FILE" "$SOURCE/glpi.crt" \
    || { log ERROR "Échec du téléchargement du certificat"; exit 3; }
chmod 644 "$CERT_FILE"

# --- 5. Installation non interactive -----------------------------------------
log INFO "Installation en cours..."
if ! perl "$WORK_DIR/installer.pl" --install \
        --server="$GLPI_URL" --tag="$TAG" --ca-cert-file="$CERT_FILE" \
        --runnow --no-question >>"$LOG_FILE" 2>&1; then
    log ERROR "Échec de l'installation (voir $LOG_FILE)"
    exit 4
fi

# Journal de l'agent dans un fichier : indispensable au watchdog
mkdir -p "$AGENT_LOG_DIR" /etc/glpi-agent/conf.d
cat > /etc/glpi-agent/conf.d/90-afritrust.cfg <<EOF
logger = file
logfile = $AGENT_LOG_DIR/glpi-agent.log
EOF

# --- Activation du service systemd et vérification ---------------------------
systemctl enable glpi-agent >>"$LOG_FILE" 2>&1
systemctl restart glpi-agent
sleep 3
if ! systemctl is-active --quiet glpi-agent; then
    log ERROR "Le service glpi-agent n'est pas actif"
    exit 5
fi
log INFO "Service glpi-agent actif"

# --- Inventaire forcé (timeout 60 s) -----------------------------------------
log INFO "Inventaire forcé"
timeout 60 glpi-agent --force >>"$LOG_FILE" 2>&1 \
    || log WARN "Inventaire forcé en échec ou interrompu (timeout 60 s)"

log INFO "SUCCÈS : agent installé et démarré, TAG=$TAG, serveur=$GLPI_URL"
