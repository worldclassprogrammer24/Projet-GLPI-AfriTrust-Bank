<#
.SYNOPSIS
    Deploiement automatise de GLPI Agent sous Windows (AfriTrust Bank - Lot 2).

.DESCRIPTION
    1. Idempotence : ne reinstalle pas si l'agent est installe et a jour (sauf -Force)
    2. Detection de l'agence (prefixe du nom d'hote, sinon sous-reseau IP) -> $Tag
    3. Telechargement silencieux du MSI et du certificat depuis le depot interne
    4. Installation /quiet avec SERVER, TAG et certificat CA (SSL verifie)
    5. Premier inventaire force (timeout 60 s) et journal C:\Logs\glpi_deploy.log

.PARAMETER GlpiIp
    IP du serveur GLPI dans le sous-reseau du poste. Deduite automatiquement si absente
    (192.168.<site>.10).

.PARAMETER Source
    URL du depot de deploiement. Defaut : http://<GlpiIp>:8000

.PARAMETER Tag
    Impose un TAG (sinon detection automatique).

.PARAMETER Force
    Reinstalle meme si l'agent est deja a jour.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Deploy-GlpiAgent.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Deploy-GlpiAgent.ps1 -GlpiIp 192.168.20.10 -Source http://192.168.20.10:8000 -Force

.NOTES
    Codes de sortie : 0 succes | 1 erreur inattendue | 2 reseau/depot injoignable
                      3 installation MSI en echec | 4 service absent apres installation
    A lancer en administrateur (ou SYSTEM via tache planifiee au demarrage).
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$GlpiIp,
    [string]$Source,
    [string]$Tag,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# ============================ CONFIGURATION ============================
$LogDir   = "C:\Logs"
$LogFile  = Join-Path $LogDir "glpi_deploy.log"
$BaseDir  = "C:\ProgramData\AfriTrust"              # donnees persistantes (certificat)
$WorkDir  = Join-Path $BaseDir "deploy"             # fichiers temporaires
$CertFile = Join-Path $BaseDir "glpi.crt"           # certificat du serveur, lu par l'agent
$AgentDir = "C:\Program Files\GLPI-Agent"

# Troisieme octet du sous-reseau -> TAG de l'agence
$SiteMap  = @{ "10" = "SIEGE"; "20" = "AGENCE_DLA"; "30" = "AGENCE_YDE"; "40" = "AGENCE_BAF" }
# =======================================================================

New-Item -ItemType Directory -Path $LogDir, $WorkDir -Force | Out-Null

function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO")
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

# Premiere IPv4 appartenant a l'un des 4 sous-reseaux du projet
function Get-LocalSite {
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.IPAddress -match '^192\.168\.(10|20|30|40)\.' }
    foreach ($ip in $ips) {
        if ($ip.IPAddress -match '^192\.168\.(\d+)\.') {
            return @{ Ip = $ip.IPAddress; Octet = $Matches[1] }
        }
    }
    return $null
}

# TAG : prefixe du nom d'hote, sinon sous-reseau IP, sinon NON_CLASSE
function Get-AgencyTag {
    switch -Wildcard ($env:COMPUTERNAME.ToUpper()) {
        "AG-DLA-*" { return "AGENCE_DLA" }
        "AG-YDE-*" { return "AGENCE_YDE" }
        "AG-BAF-*" { return "AGENCE_BAF" }
        "SIEGE-*"  { return "SIEGE" }
    }
    $site = Get-LocalSite
    if ($site -and $SiteMap.ContainsKey($site.Octet)) { return $SiteMap[$site.Octet] }
    return "NON_CLASSE"
}

# Version de l'agent installe (registre), ou $null
function Get-InstalledAgentVersion {
    $keys = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    $app = Get-ItemProperty $keys -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -like "GLPI Agent*" } | Select-Object -First 1
    if ($app) { return $app.DisplayVersion }
    return $null
}

# Normalise "1.11", "1.11.0" ou "1.11-1" en [version] a 3 composantes (comparaison fiable)
function ConvertTo-Ver {
    param([string]$s)
    $p = @($s -split '[^\d]+' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
    while ($p.Count -lt 3) { $p += 0 }
    return [version]($p[0..2] -join '.')
}

function Get-RepoFile {
    param([string]$Name, [string]$Dest)
    $url = "$Source/$Name"
    Write-Log "Telechargement : $url"
    Invoke-WebRequest -Uri $url -OutFile $Dest -UseBasicParsing -TimeoutSec 120
    if (-not (Test-Path $Dest) -or (Get-Item $Dest).Length -lt 100) { throw "Fichier invalide : $Name" }
}

# ============================== PROGRAMME ==============================
try {
    Write-Log "===== Debut du deploiement GLPI Agent sur $env:COMPUTERNAME ====="

    # --- Etape 2 : TAG et adresses ---
    $site = Get-LocalSite
    if (-not $Tag) { $Tag = Get-AgencyTag }
    Write-Log "TAG : $Tag"
    if ($Tag -eq "NON_CLASSE") { Write-Log "Agence non reconnue (hote '$env:COMPUTERNAME')" "WARN" }

    if (-not $GlpiIp) {
        if ($site) { $GlpiIp = "192.168.$($site.Octet).10" }
        else { Write-Log "IP GLPI introuvable : utiliser -GlpiIp" "ERROR"; exit 2 }
    }
    if (-not $Source) { $Source = "http://${GlpiIp}:8000" }
    $GlpiUrl = "https://$GlpiIp/"
    Write-Log "Serveur GLPI : $GlpiUrl | Depot : $Source"

    # --- Connectivite avant toute action ---
    if (-not (Test-NetConnection -ComputerName $GlpiIp -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
        Write-Log "Serveur GLPI injoignable sur $GlpiIp:443" "ERROR"
        exit 2
    }

    # --- Etape 1 : idempotence ---
    $service     = Get-Service -Name "glpi-agent" -ErrorAction SilentlyContinue
    $installed   = Get-InstalledAgentVersion
    $repoVersion = $null
    try { $repoVersion = (Invoke-WebRequest -Uri "$Source/version.txt" -UseBasicParsing -TimeoutSec 15).Content.Trim() }
    catch { Write-Log "version.txt indisponible sur le depot" "WARN" }

    if ($service -and $installed -and -not $Force) {
        Write-Log "Agent installe (version $installed), service : $($service.Status)"
        $upToDate = (-not $repoVersion) -or ((ConvertTo-Ver $installed) -ge (ConvertTo-Ver $repoVersion))
        if ($upToDate) {
            if ($service.Status -ne "Running") { Start-Service -Name "glpi-agent"; Write-Log "Service redemarre" }
            Write-Log "Agent a jour : rien a faire."
            exit 0
        }
        Write-Log "Mise a jour : $installed -> $repoVersion"
    }

    # --- Etape 3 : recuperation du MSI et du certificat ---
    $msi = Join-Path $WorkDir "glpi-agent.msi"
    try {
        Get-RepoFile -Name "glpi.crt"       -Dest $CertFile
        Get-RepoFile -Name "glpi-agent.msi" -Dest $msi
    } catch {
        Write-Log "Depot inaccessible : $($_.Exception.Message)" "ERROR"
        exit 2
    }

    # --- Etape 4 : installation silencieuse ---
    $msiLog  = Join-Path $LogDir "glpi_msi_install.log"
    $msiArgs = @(
        "/i", "`"$msi`"", "/quiet", "/norestart", "/l*v", "`"$msiLog`"",
        "SERVER=`"$GlpiUrl`"",
        "TAG=`"$Tag`"",
        "CA_CERT_FILE=`"$CertFile`"",
        "LOGGER=File",
        "ADD_FIREWALL_EXCEPTION=1",
        "RUNNOW=1"
    )
    Write-Log "Installation en cours..."
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
    if ($proc.ExitCode -notin 0, 3010) {
        Write-Log "Echec msiexec, code $($proc.ExitCode) (voir $msiLog)" "ERROR"
        exit 3
    }
    Write-Log "Installation terminee (code $($proc.ExitCode))"

    Start-Sleep -Seconds 5
    $service = Get-Service -Name "glpi-agent" -ErrorAction SilentlyContinue
    if (-not $service) { Write-Log "Service glpi-agent absent apres installation" "ERROR"; exit 4 }
    if ($service.Status -ne "Running") { Start-Service -Name "glpi-agent" }
    Set-Service -Name "glpi-agent" -StartupType Automatic
    Write-Log "Service glpi-agent : $((Get-Service glpi-agent).Status)"

    # --- Etape 5 : premier inventaire force, avec timeout de 60 s ---
    $bat = Join-Path $AgentDir "glpi-agent.bat"
    if (Test-Path $bat) {
        Write-Log "Inventaire force (timeout 60 s)"
        $job = Start-Job -ScriptBlock { param($b) & $b --force 2>&1 } -ArgumentList $bat
        if (Wait-Job -Job $job -Timeout 60) {
            Receive-Job -Job $job | ForEach-Object { Add-Content -Path $LogFile -Value "    $_" -Encoding UTF8 }
            Write-Log "Inventaire force termine"
        } else {
            Stop-Job -Job $job
            Write-Log "Inventaire force interrompu (timeout 60 s)" "WARN"
        }
        Remove-Job -Job $job -Force
    } else {
        Write-Log "glpi-agent.bat introuvable : inventaire assure par RUNNOW=1" "WARN"
    }

    Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "SUCCES : agent installe, TAG=$Tag, serveur=$GlpiUrl"
    exit 0
}
catch {
    Write-Log "Erreur inattendue : $($_.Exception.Message)" "ERROR"
    exit 1
}
