# GLPI AfriTrust Bank : inventaire automatisé multi-sites

Automatisation de la gestion de parc d'une banque multi-agences avec **GLPI** :
déploiement automatique de l'agent d'inventaire (Windows et Linux), classement automatique
des machines par agence grâce à un **TAG**, et supervision / auto-réparation (watchdog).

> Projet Licence 3 : Administration Systèmes et Réseaux.

## 1. Architecture

Le serveur central **GLPI-SRV01** (Ubuntu) héberge GLPI en HTTPS, un **dépôt de déploiement**
HTTP (port 8000) et un **récepteur d'alertes** (port 9000). Il est aussi le **routeur** entre les
4 sous-réseaux (une carte réseau par site, adresse `.10` dans chacun).

| Site | Sous-réseau | IP du serveur | TAG | Machine | IP |
|---|---|---|---|---|---|
| Siège | 192.168.10.0/24 | 192.168.10.10 | `SIEGE` | SIEGE-PC01 (Windows) | 192.168.10.20 |
| Agence Douala | 192.168.20.0/24 | 192.168.20.10 | `AGENCE_DLA` | AG-DLA-PC01 (Windows) | 192.168.20.21 |
| Agence Yaoundé | 192.168.30.0/24 | 192.168.30.10 | `AGENCE_YDE` | AG-YDE-SRV01 (Ubuntu) | 192.168.30.31 |
| Agence Bafoussam | 192.168.40.0/24 | 192.168.40.10 | `AGENCE_BAF` | AG-BAF-PC01 (Ubuntu) | 192.168.40.41 |

### Logique d'attribution du TAG

Ordre de décision (identique sous Windows et Linux) :
1. option `-Tag` / `--tag` si fournie ;
2. (Linux) fichier `/etc/agence.conf` contenant `TAG=...` ;
3. préfixe du nom d'hôte : `SIEGE-*`, `AG-DLA-*`, `AG-YDE-*`, `AG-BAF-*` ;
4. sous-réseau IP (3e octet : 10, 20, 30, 40) ;
5. sinon `NON_CLASSE`.

L'IP du serveur GLPI est déduite de la même façon (`192.168.<site>.10`) si elle n'est pas donnée.
Côté GLPI, des **règles d'affectation d'entité** (critère *Tag*) classent la machine dans la
bonne entité, et des **règles de localisation** renseignent le champ *Lieu*.

## 2. Contenu du dépôt

```
.
├── README.md
├── windows/
│   ├── Deploy-GlpiAgent.ps1     # Lot 2 : déploiement Windows
│   └── watchdog_glpi.ps1        # Lot 4 : supervision Windows
├── linux/
│   ├── deploy_glpi_agent.sh     # Lot 3 : déploiement Linux
│   └── watchdog_glpi.sh         # Lot 4 : supervision Linux
├── server/
│   ├── setup-server.sh          # installation du dépôt, du récepteur d'alertes, du routage
│   ├── refresh-deploy-repo.sh   # mise à jour du dépôt (MSI, installeur Perl, certificat)
│   └── alert-receiver.py        # webhook central des alertes
└── docs/
    ├── DAT.pdf                  # Dossier d'Architecture Technique
    └── captures/                # preuves de classement et de tests
```

## 3. Prérequis

**Serveur** : GLPI avec **inventaire natif** activé (Administration > Inventaire), Apache en HTTPS avec
un certificat dont le **SAN** contient les 4 IP du serveur, entités et règles du Lot 1 créées,
Internet + DNS fonctionnels pour remplir le dépôt (`nameservers` dans Netplan).

**Clients** : Windows 10/11 avec PowerShell 5.1 et session administrateur ; Debian/Ubuntu avec root,
`curl` et `perl` ; accès réseau à l'IP du serveur dans leur sous-réseau (ports 443, 8000, 9000).

## 4. Utilisation

### 4.1 Serveur (une fois)
```bash
cd server
sudo ./setup-server.sh
curl -s http://127.0.0.1:8000/version.txt     # doit afficher la version de l'agent
curl -s http://127.0.0.1:9000/                # alert-receiver OK
```
Mettre à jour le dépôt plus tard : `sudo /usr/local/sbin/refresh-deploy-repo.sh`.
Alertes reçues : `sudo tail -f /var/log/glpi-alerts.log`.

### 4.2 Windows (Lot 2)
PowerShell **en administrateur** :
```powershell
# Tout est déduit automatiquement (TAG, IP du serveur, dépôt)
powershell -ExecutionPolicy Bypass -File .\Deploy-GlpiAgent.ps1

# Ou explicitement
powershell -ExecutionPolicy Bypass -File .\Deploy-GlpiAgent.ps1 -GlpiIp 192.168.20.10 -Source http://192.168.20.10:8000 -Force

Get-Content C:\Logs\glpi_deploy.log -Tail 20
```
Au démarrage (mode « pull », idempotent donc sans risque) :
```powershell
$a = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File C:\AfriTrust\Deploy-GlpiAgent.ps1"
Register-ScheduledTask -TaskName "GLPI-Deploy" -Action $a -Trigger (New-ScheduledTaskTrigger -AtStartup) -User SYSTEM -RunLevel Highest
```
À distance (mode « push », après `Enable-PSRemoting -Force` sur la cible) :
```powershell
Invoke-Command -ComputerName 192.168.20.21 -Credential (Get-Credential) -FilePath .\Deploy-GlpiAgent.ps1
```

### 4.3 Linux (Lot 3)
```bash
chmod +x deploy_glpi_agent.sh
sudo ./deploy_glpi_agent.sh                        # tout est déduit
sudo ./deploy_glpi_agent.sh --glpi-ip 192.168.30.10 --force   # explicite
tail -20 /var/log/glpi_deploy.log ; systemctl status glpi-agent
```

### 4.4 Watchdog (Lot 4)

**Avant la première planification, vérifier le motif de succès** (ligne du log de l'agent qui
confirme l'envoi) puis l'ajuster dans la variable `SuccessPattern` / `SUCCESS_PATTERN` :
```powershell
Select-String -Path "C:\Program Files\GLPI-Agent\logs\glpi-agent.log" -Pattern "inventory" | Select-Object -Last 10
```
```bash
grep -i inventory /var/log/glpi-agent/glpi-agent.log | tail
```

Planification quotidienne :
```powershell
# Windows (admin)
$a = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File C:\AfriTrust\watchdog_glpi.ps1"
Register-ScheduledTask -TaskName "GLPI-Watchdog" -Action $a -Trigger (New-ScheduledTaskTrigger -Daily -At 6:30am) -User SYSTEM -RunLevel Highest
```
```bash
# Linux (root)
sudo install -m 755 watchdog_glpi.sh /usr/local/sbin/watchdog_glpi.sh
echo '30 6 * * * root /usr/local/sbin/watchdog_glpi.sh' | sudo tee /etc/cron.d/glpi-watchdog
```
Le watchdog (1) redémarre le service s'il est arrêté, (2) force un inventaire (timeout 60 s, 2 essais)
si le dernier envoi réussi date de plus de 48 h, (3) en cas d'échec persistant écrit dans
`glpi_alerts.log` et envoie une alerte JSON au serveur.

## 5. Recette (démonstration)

| Test | Résultat attendu |
|---|---|
| Script sur une machine vierge | Agent installé, machine visible dans GLPI |
| Relance du script | « Agent à jour : rien à faire », pas de réinstallation |
| Entité de chacune des 4 machines | Classement automatique selon le TAG (4/4) |
| `Stop-Service glpi-agent` / `systemctl stop glpi-agent` puis watchdog | Service redémarré automatiquement |
| Blocage du port 443 puis watchdog | Relances, puis alerte reçue dans `/var/log/glpi-alerts.log` |

Blocage du port 443 pour la démo : règle `New-NetFirewallRule -DisplayName "TEST443" -Direction Outbound -RemotePort 443 -Protocol TCP -Action Block`
(Windows) ou `sudo iptables -A OUTPUT -p tcp --dport 443 -j REJECT` (Linux). À retirer ensuite
(`Remove-NetFirewallRule -DisplayName TEST443` / `sudo iptables -D OUTPUT -p tcp --dport 443 -j REJECT`).
Pour une démo immédiate, lancer le watchdog avec `-MaxAgeHours 0` (Windows) ou `MAX_AGE_HOURS=0` (Linux).

## 6. Dépannage

| Symptôme | Piste |
|---|---|
| Machine en Entité racine | Règle d'affectation (critère Tag) absente, ou ancienne fiche non purgée dans la corbeille GLPI |
| Erreur SSL | Le certificat doit contenir l'IP utilisée (SAN) et `glpi.crt` être dans `/srv/deploy` |
| `Could not resolve host` sur le serveur | Ajouter `nameservers` dans Netplan, puis `netplan apply` |
| Le watchdog alerte toujours | Motif `SuccessPattern` incorrect : vérifier le log de l'agent (§ 4.4) |
| Pas de logs agent sous Linux | `/etc/glpi-agent/conf.d/90-afritrust.cfg` (logger = file), puis `systemctl restart glpi-agent` |
| Accents illisibles (PowerShell) | Enregistrer les `.ps1` en UTF-8 avec BOM |

## 7. Limites connues

Certificat auto-signé, dépôt HTTP sans authentification, alertes simulées par webhook : acceptables
en maquette. En production : PKI interne, déploiement par GPO ou gestionnaire de configuration,
dépôt authentifié, comptes de service dédiés, alerte réelle (mail, outil de supervision).
