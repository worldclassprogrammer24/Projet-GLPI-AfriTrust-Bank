#!/usr/bin/env bash
# =============================================================================
# watchdog_glpi.sh : supervision et auto-réparation de GLPI Agent (Linux)
# AfriTrust Bank - Lot 4
#
#   1. Vérifie que le service glpi-agent est actif ; sinon le redémarre
#   2. Lit les logs de l'agent : dernier envoi d'inventaire réussi < 48 h,
#      sinon force un inventaire (timeout 60 s)
#   3. Échec persistant : alerte (fichier /var/log/glpi_alerts.log + webhook JSON)
#
# Planification : cron quotidien (voir README).
# Codes de sortie : 0 OK | 1 pas root | 2 service absent | 3 service impossible
#                   à démarrer | 4 inventaire périmé
# =============================================================================
set -uo pipefail

# --------------------------- CONFIGURATION -----------------------------------
MAX_AGE_HOURS="${MAX_AGE_HOURS:-48}"
RETRIES="${RETRIES:-2}"
AGENT_LOG="/var/log/glpi-agent/glpi-agent.log"
LOG_FILE="/var/log/glpi_watchdog.log"
ALERT_FILE="/var/log/glpi_alerts.log"
# Motif (regex, insensible à la casse) de la ligne confirmant un envoi d'inventaire.
# À VÉRIFIER sur votre agent : grep -i inventory /var/log/glpi-agent/glpi-agent.log | tail
SUCCESS_PATTERN='inventory.*sent'
# -----------------------------------------------------------------------------

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" | tee -a "$LOG_FILE"; }

if [[ $EUID -ne 0 ]]; then
    echo "Ce script doit être exécuté en root." >&2
    exit 1
fi
touch "$LOG_FILE" "$ALERT_FILE"

# URL du récepteur d'alertes : déduite du serveur configuré dans l'agent
if [[ -z "${ALERT_URL:-}" ]]; then
    SERVER_HOST=$(grep -rhE '^[[:space:]]*server[[:space:]]*=' /etc/glpi-agent/ 2>/dev/null \
                  | head -n1 | sed -E 's/^[^=]*=[[:space:]]*//; s#^https?://##; s#[/:, ].*$##' || true)
    [[ -n "$SERVER_HOST" ]] && ALERT_URL="http://${SERVER_HOST}:9000/alert" || ALERT_URL=""
fi

# --- Alerte : fichier local + webhook JSON -----------------------------------
send_alert() {
    local type="$1" message="$2" ip json
    ip=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 \
         | grep -E '^192\.168\.(10|20|30|40)\.' | head -n1 || true)
    json=$(printf '{"host":"%s","ip":"%s","type":"%s","message":"%s","timestamp":"%s"}' \
           "$(hostname)" "$ip" "$type" "$message" "$(date '+%Y-%m-%dT%H:%M:%S')")
    log ERROR "ALERTE [$type] $message"
    echo "$json" >> "$ALERT_FILE"
    if [[ -n "$ALERT_URL" ]]; then
        if curl -fsS --max-time 10 -X POST -H 'Content-Type: application/json' \
                -d "$json" "$ALERT_URL" >/dev/null 2>&1; then
            log INFO "Alerte transmise à $ALERT_URL"
        else
            log WARN "Envoi de l'alerte impossible vers $ALERT_URL"
        fi
    fi
}

# --- Date (epoch) du dernier envoi d'inventaire réussi -----------------------
# Format des logs : [Mon Nov 23 10:46:12 2026][info] ...
last_inventory_epoch() {
    [[ -f "$AGENT_LOG" ]] || return 0
    local line ts
    line=$(tail -n 3000 "$AGENT_LOG" | grep -iE "$SUCCESS_PATTERN" | tail -n1 || true)
    [[ -n "$line" ]] || return 0
    ts=$(sed -E 's/^\[([^]]+)\].*/\1/' <<<"$line")
    date -d "$ts" +%s 2>/dev/null || true
}

is_fresh() {
    local last now
    last=$(last_inventory_epoch)
    [[ -n "$last" ]] || return 1
    now=$(date +%s)
    (( now - last < MAX_AGE_HOURS * 3600 ))
}

log INFO "===== Watchdog GLPI sur $(hostname) ====="

# --- Contrôle 1 : service ----------------------------------------------------
if ! systemctl cat glpi-agent >/dev/null 2>&1; then
    send_alert "SERVICE_ABSENT" "Le service glpi-agent n'est pas installé"
    exit 2
fi
if systemctl is-active --quiet glpi-agent; then
    log INFO "Service glpi-agent : active"
else
    log WARN "Service inactif : redémarrage"
    systemctl restart glpi-agent
    sleep 5
    if ! systemctl is-active --quiet glpi-agent; then
        send_alert "SERVICE_DOWN" "Redémarrage du service glpi-agent impossible"
        exit 3
    fi
    log INFO "Service redémarré avec succès"
fi

# --- Contrôle 2 : fraîcheur du dernier inventaire ----------------------------
LAST=$(last_inventory_epoch)
if [[ -n "$LAST" ]]; then
    log INFO "Dernier inventaire réussi : $(date -d "@$LAST" '+%Y-%m-%d %H:%M:%S')"
else
    log WARN "Aucun inventaire réussi trouvé dans $AGENT_LOG"
fi

attempt=0
while ! is_fresh && (( attempt < RETRIES )); do
    attempt=$((attempt + 1))
    log WARN "Inventaire trop ancien (> ${MAX_AGE_HOURS} h) : relance forcée, tentative $attempt/$RETRIES"
    timeout 60 glpi-agent --force >>"$LOG_FILE" 2>&1 \
        || log WARN "Inventaire forcé en échec ou interrompu (timeout 60 s)"
    sleep 5
done

# --- Contrôle 3 : verdict ----------------------------------------------------
if is_fresh; then
    log INFO "OK : inventaire à jour"
    exit 0
fi
send_alert "INVENTORY_STALE" "Aucun inventaire réussi depuis plus de ${MAX_AGE_HOURS} h après ${RETRIES} relances"
exit 4
