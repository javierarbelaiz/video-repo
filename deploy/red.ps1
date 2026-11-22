# Secret videorepo-red: las direcciones de la casa que la app necesita y que NO van al repo en claro.
#   .\deploy\red.ps1            pide NODE_IP y CAMERA_URL, carga el Secret y guarda la copia cifrada
#   .\deploy\red.ps1 aplicar    vuelve a cargar el Secret desde deploy\secretos\videorepo-red.enc.yaml
# NODE_IP: IP del nodo de k3s que atiende la TV (cert HTTPS para WebXR y mDNS videorepo.local).
# CAMERA_URL: grabador de la cámara de la entrada, por ejemplo http://<ip-del-box>:8191
# La copia se cifra con SOPS (age, .sops.yaml); el texto plano solo pasa por un temporal con permisos
# del usuario, que se borra al terminar, y por la tubería de ssh hasta kubectl.
param([Parameter(Position = 0)][ValidateSet("cargar", "aplicar")][string]$Accion = "cargar")
$ErrorActionPreference = "Stop"
$NodeHost = if ($env:NODE_HOST) { $env:NODE_HOST } else { "thehook@mykaly" }
$Root = Split-Path $PSScriptRoot -Parent
$Cifrado = Join-Path $Root "deploy\secretos\videorepo-red.enc.yaml"
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

if ($Accion -eq "aplicar") {
    if (-not (Test-Path $Cifrado)) { Write-Host "No existe $Cifrado" -ForegroundColor Red; exit 1 }
    $t = Temporal
    try {
        & cmd.exe /c "sops --decrypt `"$Cifrado`" > `"$t`""
        if ($LASTEXITCODE -ne 0) { throw "sops no pudo descifrar" }
        Enviar $t
    } finally { Remove-Item -Force $t -ErrorAction SilentlyContinue }
    Write-Host "Listo: Secret videorepo-red restaurado."
    exit 0
}

$NodeIp = (Read-Host "IP del nodo que atiende la TV (NODE_IP)").Trim()
if ($NodeIp -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$' -or ($Matches[1..4] | Where-Object { [int]$_ -gt 255 })) {
    Write-Host "Eso no es una IPv4." -ForegroundColor Red; exit 1
}
$CameraUrl = (Read-Host "URL del grabador de la camara (CAMERA_URL, Enter = sin camara)").Trim().TrimEnd('/')
if ($CameraUrl -and $CameraUrl -notmatch '^http://[A-Za-z0-9.\-]+(:\d{1,5})?$') {
    Write-Host "Tiene que ser http://<ip o nombre>[:puerto], sin ruta." -ForegroundColor Red; exit 1
}

$yaml = "apiVersion: v1`nkind: Secret`nmetadata:`n  name: videorepo-red`n  namespace: videorepo`ntype: Opaque`nstringData:`n  NODE_IP: `"$NodeIp`"`n"
if ($CameraUrl) { $yaml += "  CAMERA_URL: `"$CameraUrl`"`n" }
$t = Temporal
try {
    [IO.File]::WriteAllText($t, $yaml, (New-Object Text.UTF8Encoding($false)))
    New-Item -ItemType Directory -Force (Split-Path $Cifrado) | Out-Null
    $enc = & sops --encrypt --filename-override $Cifrado $t
    if ($LASTEXITCODE -ne 0) { throw "sops no pudo cifrar" }
    [IO.File]::WriteAllText($Cifrado, (($enc -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
    Enviar $t
} finally {
    Remove-Item -Force $t -ErrorAction SilentlyContinue
    $yaml = $null
}
Write-Host "Listo: Secret videorepo-red cargado y copia cifrada en deploy\secretos\videorepo-red.enc.yaml (commitearla)."
