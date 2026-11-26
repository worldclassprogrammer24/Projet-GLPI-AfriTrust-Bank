<#
.SYNOPSIS
    Supervision et auto-reparation de GLPI Agent (AfriTrust Bank - Lot 4, Windows).

.DESCRIPTION
    1. Verifie que le service glpi-agent tourne ; sinon le redemarre
    2. Lit les logs de l'agent : dernier envoi d'inventaire reussi < 48 h, sinon force un inventaire
    3. Echec persistant : alerte (fichier C:\Logs\glpi_alerts.log + webhook JSON vers le serveur)

.PARAMETER AlertUrl
    URL du recepteur d'alertes. Defaut : http://<serveur de l'agent>:9000/alert

.PARAMETER MaxAgeHours
    Age maximal du dernier inventaire reussi (defaut 48).

.PARAMETER Retries
    Nombre de relances d'inventaire avant alerte (defaut 2).

.NOTES
    Codes de sortie : 0 OK | 2 service absent | 3 service impossible a demarrer | 4 inventaire perime
    Planification : tache planifiee quotidienne, compte SYSTEM (voir README).
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$AlertUrl,
    [int]$MaxAgeHours = 48,
    [int]$Retries = 2
)

$ErrorActionPreference = "Continue"

# ============================ CONFIGURATION ============================
$LogDir    = "C:\Logs"
$LogFile   = Join-Path $LogDir "glpi_watchdog.log"
$AlertFile = Join-Path $LogDir "glpi_alerts.log"
$AgentDir  = "C:\Program Files\GLPI-Agent"
$AgentLogs = @("$AgentDir\logs\glpi-agent.log", "C:\ProgramData\GLPI-Agent\logs\glpi-agent.log")

# Motif (regex, insensible a la casse) de la ligne qui confirme un envoi d'inventaire.
# A VERIFIER sur votre agent : Select-String -Path <log agent> -Pattern "inventory" | Select -Last 10
$SuccessPattern = 'inventory.*sent'
# =======================================================================

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO")
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

# Deduit l'URL du recepteur d'alertes a partir du serveur configure dans l'agent
if (-not $AlertUrl) {
    $srv = (Get-ItemProperty "HKLM:\SOFTWARE\GLPI-Agent" -ErrorAction SilentlyContinue).server
    if ($srv) {
        try { $AlertUrl = "http://{0}:9000/alert" -f ([uri]($srv -split '[ ,]')[0]).Host } catch { }
    }
}

function Send-Alert {
    param([string]$Type, [string]$Message)
    $myIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
             Where-Object { $_.IPAddress -match '^192\.168\.(10|20|30|40)\.' } |
             Select-Object -First 1).IPAddress
    $json = [ordered]@{
        host      = $env:COMPUTERNAME
        ip        = $myIp
        type      = $Type
        message   = $Message
        timestamp = (Get-Date).ToString("s")
    } | ConvertTo-Json -Compress

    Write-Log "ALERTE [$Type] $Message" "ERROR"
    Add-Content -Path $AlertFile -Value $json -Encoding UTF8          # fichier d'erreur local
    if ($AlertUrl) {
        try {
            Invoke-RestMethod -Uri $AlertUrl -Method Post -Body $json -ContentType "application/json" -TimeoutSec 10 | Out-Null
            Write-Log "Alerte transmise a $AlertUrl"
        } catch {
            Write-Log "Envoi de l'alerte impossible : $($_.Exception.Message)" "WARN"
        }
    }
}

# Date du dernier envoi d'inventaire reussi, lue dans les logs de l'agent ($null si aucun)
function Get-LastInventory {
    $best = $null
    foreach ($f in $AgentLogs) {
        if (-not (Test-Path $f)) { continue }
        $lines = Get-Content -Path $f -Tail 3000 -ErrorAction SilentlyContinue |
                 Where-Object { $_ -match $SuccessPattern }
        foreach ($l in $lines) {
            # Format des logs : [Mon Nov 23 10:46:12 2026][info] ...
            if ($l -match '^\[(?<d>[A-Za-z]{3} [A-Za-z]{3}\s+\d{1,2} \d{2}:\d{2}:\d{2} \d{4})\]') {
                $d = $Matches['d'] -replace '\s+', ' '
                try {
                    $t = [datetime]::ParseExact($d, 'ddd MMM d HH:mm:ss yyyy', [Globalization.CultureInfo]::InvariantCulture)
                } catch { continue }
                if (-not $best -or $t -gt $best) { $best = $t }
            }
        }
    }
    return $best
}

function Test-Fresh {
    $last = Get-LastInventory
    if (-not $last) { return $false }
    return (((Get-Date) - $last).TotalHours -lt $MaxAgeHours)
}

# Inventaire force avec timeout de 60 s : un reseau coupe ne bloque jamais le script
function Invoke-ForcedInventory {
    $bat = Join-Path $AgentDir "glpi-agent.bat"
    if (-not (Test-Path $bat)) { Write-Log "glpi-agent.bat introuvable" "WARN"; return }
    $job = Start-Job -ScriptBlock { param($b) & $b --force 2>&1 } -ArgumentList $bat
    if (Wait-Job -Job $job -Timeout 60) {
        Receive-Job -Job $job | ForEach-Object { Add-Content -Path $LogFile -Value "    $_" -Encoding UTF8 }
    } else {
        Stop-Job -Job $job
        Write-Log "Inventaire force interrompu (timeout 60 s)" "WARN"
    }
    Remove-Job -Job $job -Force
}

# ============================== PROGRAMME ==============================
Write-Log "===== Watchdog GLPI sur $env:COMPUTERNAME ====="

# --- Controle 1 : service ---
$svc = Get-Service -Name "glpi-agent" -ErrorAction SilentlyContinue
if (-not $svc) {
    Send-Alert "SERVICE_ABSENT" "Le service glpi-agent n'est pas installe"
    exit 2
}
if ($svc.Status -ne "Running") {
    Write-Log "Service $($svc.Status) : redemarrage" "WARN"
    try { Start-Service -Name "glpi-agent" -ErrorAction Stop } catch { Write-Log $_.Exception.Message "WARN" }
    Start-Sleep -Seconds 5
    if ((Get-Service -Name "glpi-agent").Status -ne "Running") {
        Send-Alert "SERVICE_DOWN" "Redemarrage du service glpi-agent impossible"
        exit 3
    }
    Write-Log "Service redemarre avec succes"
} else {
    Write-Log "Service glpi-agent : Running"
}

# --- Controle 2 : fraicheur du dernier inventaire ---
$last = Get-LastInventory
Write-Log ("Dernier inventaire reussi : {0}" -f $(if ($last) { $last.ToString("yyyy-MM-dd HH:mm:ss") } else { "aucun trouve" }))

$attempt = 0
while (-not (Test-Fresh) -and $attempt -lt $Retries) {
    $attempt++
    Write-Log "Inventaire trop ancien (> $MaxAgeHours h) : relance forcee, tentative $attempt/$Retries" "WARN"
    Invoke-ForcedInventory
    Start-Sleep -Seconds 5
}

# --- Controle 3 : verdict ---
if (Test-Fresh) {
    Write-Log "OK : inventaire a jour"
    exit 0
}
Send-Alert "INVENTORY_STALE" "Aucun inventaire reussi depuis plus de $MaxAgeHours h apres $Retries relances"
exit 4
