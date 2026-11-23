# Secret camara-restic: a dónde y con qué clave guarda el depurador los clips viejos de la cámara.
#   .\deploy\restic.ps1            lee las claves del box por SSH, carga el Secret y guarda la copia cifrada
#   .\deploy\restic.ps1 aplicar    vuelve a cargar el Secret desde deploy\secretos\camara-restic.enc.yaml
# RESTIC_REPOSITORY: rest-server del box por la tailnet (append-only: desde k3s no se puede borrar nada).
# RESTIC_PASSWORD:   la clave del repo M:\restic (la misma que usa backup-central).
# Ninguna clave se muestra: van del box a una variable, a un temporal con permisos del usuario que se borra
# al terminar, y por la tubería de ssh hasta kubectl. La copia se cifra con SOPS (age, .sops.yaml).
param([Parameter(Position = 0)][ValidateSet("cargar", "aplicar")][string]$Accion = "cargar")
$ErrorActionPreference = "Stop"
$NodeHost = if ($env:NODE_HOST) { $env:NODE_HOST } else { "thehook@mykaly" }
$BoxHost = if ($env:BOX_HOST) { $env:BOX_HOST } else { "celes@javierdesktop.local" }
$RestUser = if ($env:REST_USER) { $env:REST_USER } else { "gilway" }
$RestPort = 8000
$Root = Split-Path $PSScriptRoot -Parent
$Cifrado = Join-Path $Root "deploy\secretos\camara-restic.enc.yaml"
if (-not (Get-Command sops -ErrorAction SilentlyContinue)) { Write-Host "Falta sops." -ForegroundColor Red; exit 1 }

function Enviar([string]$Archivo) {
    # cmd.exe arma la tubería: la de PowerShell 5.1 recodifica el texto.
    & cmd.exe /c "type `"$Archivo`" | ssh -o BatchMode=yes $NodeHost `"kubectl apply -f - `" > NUL"
    if ($LASTEXITCODE -ne 0) { throw "no se pudo cargar el Secret en $NodeHost" }
}

function Temporal {
    $t = [IO.Path]::GetTempFileName()
    $yo = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls $t /inheritance:r /grant:r "*${yo}:F" | Out-Null
    if ($LASTEXITCODE -ne 0) { Remove-Item -Force $t; throw "no se pudieron restringir los permisos del temporal" }
    return $t
}

function Leer-DelBox([string]$Comando, [string]$Que) {
    $valor = (& ssh -o BatchMode=yes $BoxHost $Comando 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or -not $valor -or -not $valor.Trim()) { throw "no pude leer $Que del box ($BoxHost)" }
    return $valor.Trim()
}

if ($Accion -eq "aplicar") {
    if (-not (Test-Path $Cifrado)) { Write-Host "No existe $Cifrado" -ForegroundColor Red; exit 1 }
    $t = Temporal
    try {
        & cmd.exe /c "sops --decrypt `"$Cifrado`" > `"$t`""
        if ($LASTEXITCODE -ne 0) { throw "sops no pudo descifrar" }
        Enviar $t
    } finally { Remove-Item -Force $t -ErrorAction SilentlyContinue }
    Write-Host "Listo: Secret camara-restic restaurado."
    exit 0
}

$t = Temporal
try {
    $ip = Leer-DelBox "tailscale ip -4" "la IP de tailnet"
    if ($ip -notmatch '^100\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { throw "la IP de tailnet del box no tiene forma 100.x.x.x" }
    $clave = Leer-DelBox 'type "%USERPROFILE%\.restic\password"' "la clave del repo"
    $cred = Leer-DelBox 'type "%USERPROFILE%\.restic\rest-cred"' "la clave del rest-server"
    $repo = "rest:http://${RestUser}:$([Uri]::EscapeDataString($cred))@${ip}:$RestPort/"
    # Comillas simples de YAML: solo hay que duplicar las simples.
    $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
    $yaml = "apiVersion: v1`nkind: Secret`nmetadata:`n  name: camara-restic`n  namespace: videorepo`ntype: Opaque`nstringData:`n" +
            "  RESTIC_REPOSITORY: $(& $q $repo)`n  RESTIC_PASSWORD: $(& $q $clave)`n"
    [IO.File]::WriteAllText($t, $yaml, (New-Object Text.UTF8Encoding($false)))
    New-Item -ItemType Directory -Force (Split-Path $Cifrado) | Out-Null
    $enc = & sops --encrypt --filename-override $Cifrado $t
    if ($LASTEXITCODE -ne 0) { throw "sops no pudo cifrar" }
    [IO.File]::WriteAllText($Cifrado, (($enc -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
    Enviar $t
} finally {
    Remove-Item -Force $t -ErrorAction SilentlyContinue
    $yaml = $null; $clave = $null; $cred = $null; $repo = $null
}
Write-Host "Listo: Secret camara-restic cargado y copia cifrada en deploy\secretos\camara-restic.enc.yaml (commitearla)."
