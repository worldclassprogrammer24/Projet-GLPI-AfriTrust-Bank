#!/usr/bin/env bash
# =============================================================================
# refresh-deploy-repo.sh : met à jour le dépôt de déploiement /srv/deploy
#
# Le dépôt (servi en HTTP sur le port 8000) contient :
#   glpi.crt                    certificat du serveur GLPI (copie locale)
#   glpi-agent.msi              installeur Windows
#   glpi-agent-installer.pl     installeur Linux (Perl)
#   version.txt                 version de l'agent publiée (comparée par les scripts)
#
# Le certificat est toujours copié (opération locale). Le téléchargement GitHub
# a des timeouts courts : sans Internet/DNS, le script s'arrête vite et le dépôt
# existant reste intact.
# =============================================================================
set -uo pipefail

REPO_DIR="/srv/deploy"
CERT_SRC="/etc/ssl/certs/glpi.crt"
API="https://api.github.com/repos/glpi-project/glpi-agent/releases/latest"

[[ $EUID -eq 0 ]] || { echo "À exécuter en root." >&2; exit 1; }
mkdir -p "$REPO_DIR"

# 1. Certificat (local, ne dépend pas d'Internet)
if cp -f "$CERT_SRC" "$REPO_DIR/glpi.crt"; then
    chmod 644 "$REPO_DIR/glpi.crt"
    echo "[OK] Certificat copié"
else
    echo "[ERREUR] Certificat introuvable : $CERT_SRC" >&2
fi

# 2. Dernière version de l'agent (réseau, avec timeouts)
json=$(curl -fsS --connect-timeout 10 --max-time 30 "$API") || {
    echo "[WARN] GitHub injoignable (DNS/Internet ?) : dépôt conservé tel quel."
    exit 0
}
version=$(jq -r '.tag_name' <<<"$json" | sed 's/^v//')
msi_url=$(jq -r '.assets[].browser_download_url' <<<"$json" | grep -iE 'x64\.msi$' | head -n1)
pl_url=$(jq -r '.assets[].browser_download_url' <<<"$json" | grep -iE 'linux-installer\.pl$' | head -n1)

if [[ -z "$version" || -z "$msi_url" || -z "$pl_url" ]]; then
    echo "[ERREUR] Assets introuvables dans la release GitHub (noms changés ?)." >&2
    exit 2
fi
echo "[INFO] Version publiée : $version"

fetch() {  # fetch <url> <destination> : télécharge dans un .tmp puis remplace
    curl -fsSL --connect-timeout 10 --max-time 600 -o "$2.tmp" "$1" && mv -f "$2.tmp" "$2" \
        || { rm -f "$2.tmp"; echo "[ERREUR] Échec : $1" >&2; return 1; }
}

fetch "$msi_url" "$REPO_DIR/glpi-agent.msi"          || exit 3
fetch "$pl_url"  "$REPO_DIR/glpi-agent-installer.pl" || exit 3
echo "$version" > "$REPO_DIR/version.txt"
chmod -R a+rX "$REPO_DIR"
echo "[OK] Dépôt à jour :"
ls -lh "$REPO_DIR"
