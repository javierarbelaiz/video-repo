# Secret camara-relay: usuario y clave del relé RTSP de go2rtc (:8554 en la IP del nodo), del que toma el video
# el grabador del box. Así la cámara atiende una sola sesión, la de go2rtc.
#   .\deploy\relay.ps1            genera usuario/clave, carga el Secret, guarda la copia cifrada y apunta el
#                                 grabador del box al relé (RTSP_URL en J:\proyects\cam\.env.camera)
#   .\deploy\relay.ps1 aplicar    vuelve a cargar el Secret desde deploy\secretos\camara-relay.enc.yaml
# La clave se genera acá y no se muestra: va a un temporal con permisos del usuario (borrado al terminar),
# por ssh a kubectl y al .env.camera del box. La copia se cifra con SOPS (age, .sops.yaml).
param([Parameter(Position = 0)][ValidateSet("cargar", "aplicar")][string]$Accion = "cargar")
$ErrorActionPreference = "Stop"
$NodeHost = if ($env:NODE_HOST) { $env:NODE_HOST } else { "thehook@mykaly" }
$BoxHost = if ($env:BOX_HOST) { $env:BOX_HOST } else { "celes@100.115.232.92" }
$BoxEnv = 'J:\proyects\cam\.env.camera'
$RelayUser = "grabador"
$Root = Split-Path $PSScriptRoot -Parent
$Cifrado = Join-Path $Root "deploy\secretos\camara-relay.enc.yaml"
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
    Write-Host "Listo: Secret camara-relay restaurado."
    exit 0
}

# Clave alfanumérica: entra en una URL rtsp:// sin codificar nada.
$letras = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
$bytes = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$clave = -join ($bytes | ForEach-Object { $letras[$_ % $letras.Length] })

# Toda la salida primero: cortar la tubería de ssh lo mata y deja $LASTEXITCODE en -1.
$salida = @(& ssh -o BatchMode=yes $NodeHost "kubectl -n videorepo get secret videorepo-red -o jsonpath='{.data.NODE_IP}' | base64 -d" 2>$null)
if ($LASTEXITCODE -ne 0 -or $salida.Count -eq 0) { throw "no pude leer NODE_IP del Secret videorepo-red" }
$nodeIp = "$($salida[0])".Trim()
if ($nodeIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "NODE_IP no tiene forma de IPv4" }

$t = Temporal

try {
    $yaml = "apiVersion: v1`nkind: Secret`nmetadata:`n  name: camara-relay`n  namespace: videorepo`ntype: Opaque`nstringData:`n" +
            "  RELAY_USER: '$RelayUser'`n  RELAY_PASS: '$clave'`n"
    [IO.File]::WriteAllText($t, $yaml, (New-Object Text.UTF8Encoding($false)))
    New-Item -ItemType Directory -Force (Split-Path $Cifrado) | Out-Null
    $enc = & sops --encrypt --filename-override $Cifrado $t
    if ($LASTEXITCODE -ne 0) { throw "sops no pudo cifrar" }
    [IO.File]::WriteAllText($Cifrado, (($enc -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
    Enviar $t

    # .env.camera del box: reemplaza (o agrega) RTSP_URL. Viaja por stdin, no por la línea de comandos.
    $url = "rtsp://${RelayUser}:${clave}@${nodeIp}:8554/entrada"
    $script = @"
`$f = '$BoxEnv'
`$url = [Console]::In.ReadLine()
`$lineas = @(if (Test-Path `$f) { Get-Content `$f | Where-Object { `$_ -notmatch '^\s*RTSP_URL=' } })
`$lineas += "RTSP_URL=`$url"
[IO.File]::WriteAllLines(`$f, `$lineas, (New-Object Text.UTF8Encoding(`$false)))
'ok'
"@
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $res = @($url | & ssh -o BatchMode=yes $BoxHost "powershell -NoProfile -EncodedCommand $b64" 2>$null)
    if ($LASTEXITCODE -ne 0 -or ($res -notcontains 'ok')) { throw "no pude escribir RTSP_URL en $BoxEnv" }
} finally {
    Remove-Item -Force $t -ErrorAction SilentlyContinue
    $yaml = $null; $clave = $null; $url = $null
}
Write-Host "Listo: Secret camara-relay cargado (copia cifrada en deploy\secretos\camara-relay.enc.yaml) y el grabador apunta al relé."
Write-Host "Reiniciá go2rtc y el grabador para que tomen la configuración."
