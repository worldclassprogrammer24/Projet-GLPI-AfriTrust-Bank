#!/usr/bin/env bash
# =============================================================================
# setup-server.sh : prépare GLPI-SRV01 pour le déploiement multi-sites
#
# À lancer UNE FOIS, depuis le dossier server/ du dépôt :  sudo ./setup-server.sh
#
# Prérequis : GLPI + Apache HTTPS déjà en place, certificat /etc/ssl/certs/glpi.crt
#             (avec les 4 IP en SAN), Internet/DNS pour apt et GitHub.
#
# Actions : routage IP persistant, dépôt HTTP (port 8000), récepteur d'alertes
#           (port 9000), ouverture du pare-feu si ufw est actif, remplissage du dépôt.
# =============================================================================
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "À exécuter en root (sudo)." >&2; exit 1; }
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "[1/6] Paquets"
apt-get update -qq
apt-get install -y -qq python3 curl jq

echo "[2/6] Routage IP persistant (le serveur relie les 4 sous-réseaux)"
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-afritrust.conf
sysctl --system >/dev/null

echo "[3/6] Installation des scripts"
install -d -m 755 /srv/deploy /opt/afritrust
install -m 755 "$SRC_DIR/refresh-deploy-repo.sh" /usr/local/sbin/refresh-deploy-repo.sh
install -m 755 "$SRC_DIR/alert-receiver.py"      /opt/afritrust/alert-receiver.py

echo "[4/6] Services systemd"
cat > /etc/systemd/system/glpi-deploy-repo.service <<'EOF'
[Unit]
Description=Depot de deploiement GLPI Agent (HTTP 8000)
After=network-online.target

[Service]
ExecStart=/usr/bin/python3 -m http.server 8000 --bind 0.0.0.0 --directory /srv/deploy
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/glpi-alert-receiver.service <<'EOF'
[Unit]
Description=Recepteur central des alertes du watchdog GLPI (HTTP 9000)
After=network-online.target

[Service]
ExecStart=/usr/bin/python3 /opt/afritrust/alert-receiver.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now glpi-deploy-repo glpi-alert-receiver

echo "[5/6] Pare-feu"
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow 8000/tcp
    ufw allow 9000/tcp
else
    echo "ufw inactif : rien à ouvrir"
fi

echo "[6/6] Remplissage du dépôt de déploiement"
/usr/local/sbin/refresh-deploy-repo.sh || echo "[WARN] Dépôt incomplet : corriger le DNS puis relancer refresh-deploy-repo.sh"

echo
echo "Terminé. Vérifications :"
echo "  curl -s http://127.0.0.1:8000/version.txt"
echo "  curl -s http://127.0.0.1:9000/"
echo "  systemctl status glpi-deploy-repo glpi-alert-receiver"
