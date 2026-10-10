<#
.SYNOPSIS
    Spike de "arranque sin sesion" (fase S). NO toca produccion: no se conecta a RabbitMQ con login
    (solo prueba TCP y cierra), no modifica Docker ni el Ollama normal del usuario, no instala nada.

.DESCRIPTION
    -Instalar : (admin) crea la tarea programada "Techo360Spike" que corre como SYSTEM AL INICIAR EL
                SISTEMA (no al iniciar sesion) y ejecuta spike-boot.ps1. La carpeta
                %ProgramData%\Techo360Spike se BLOQUEA con icacls (solo SYSTEM y Administradores)
                ANTES de copiar nada, porque ahi se ejecuta codigo como SYSTEM.
                Con -ProbarWsl usa un rootfs minimo de Alpine (SHA-256 fijado en este script; si no
                coincide, aborta). Sin -RootfsPath busca el .tar.gz junto al script; si no esta, lo
                descarga (requiere internet).
    -RootfsPath : ruta de un rootfs de Alpine ya descargado (no se descarga nada).
    -Quitar   : (admin) elimina la tarea, la distro WSL registrada por SYSTEM y los procesos del spike,
                mediante una tarea unica de SYSTEM, y verifica con "wsl -l -v" como SYSTEM que no
                queda registro, VM ni proceso. Luego borra la carpeta.
    -EjecutarAhora : (admin) dispara la tarea ya, sin reiniciar (el "sin sesion" real solo se
                demuestra apagando/encendiendo).
    -Estado   : (admin, la carpeta esta bloqueada) muestra boot.log.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\spike-arranque.ps1 -Instalar -ProbarWsl
#>
param(
    [switch]$Instalar,
    [switch]$Quitar,
    [switch]$Estado,
    [switch]$EjecutarAhora,
    [switch]$ProbarWsl,
    [string]$RootfsPath,
    [string[]]$RabbitHostPort = @("10.154.12.191:5672", "100.116.197.118:5672"),
    [int]$Minutos = 20
)
$ErrorActionPreference = "Stop"
$dir = Join-Path $env:ProgramData "Techo360Spike"
$task = "Techo360Spike"
$taskQuitar = "Techo360SpikeQuitar"
$log = Join-Path $dir "boot.log"
$RootfsNombre = "alpine-minirootfs-3.20.3-x86_64.tar.gz"
$RootfsSha256 = "d4e6fd67dcf75e40c451560ac7265166c2b72a0f38ddc9aae756a7de3d1efa0c"
$RootfsUrl = "https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/$RootfsNombre"

function Need-Admin {
    $a = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $a) { throw "Ejecuta esta accion en PowerShell como Administrador." }
}

# Regla (tambien para el instalador y el vigilante finales): una carpeta desde la que SYSTEM ejecuta
# codigo solo la escriben SYSTEM y Administradores. SIDs, no nombres (independiente del idioma).
function Lock-Dir([string]$d) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"   # icacls escribe avisos en stderr
    try { & icacls.exe $d /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" /T /C 2>&1 | Out-Null } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { throw "icacls no pudo bloquear $d (exit $LASTEXITCODE). No se continua." }
}

function Check-Rootfs([string]$p) {
    if (-not (Test-Path $p)) { throw "No existe el rootfs: $p" }
    $h = (Get-FileHash -Algorithm SHA256 -Path $p).Hash.ToLower()
    if ($h -ne $RootfsSha256) { throw "SHA-256 del rootfs NO coincide (esperado $RootfsSha256, obtenido $h). Se aborta." }
}

if ($Estado) {
    Need-Admin
    if (Test-Path $log) { Get-Content $log } else { Write-Host "Sin boot.log en $dir" }
    return
}

if ($Instalar) {
    Need-Admin
    $rootfsOrigen = $null
    if ($ProbarWsl) {
        # Verificar ANTES de tocar el sistema.
        if ($RootfsPath) { $rootfsOrigen = $RootfsPath }
        elseif (Test-Path (Join-Path $PSScriptRoot $RootfsNombre)) { $rootfsOrigen = Join-Path $PSScriptRoot $RootfsNombre }
        else {
            $rootfsOrigen = Join-Path $env:TEMP $RootfsNombre
            Write-Host "Descargando rootfs (3.5 MB) a $rootfsOrigen ..."
            Invoke-WebRequest -UseBasicParsing $RootfsUrl -OutFile $rootfsOrigen
        }
        Check-Rootfs $rootfsOrigen
        Write-Host "Rootfs verificado (SHA-256 OK)."
    }
    Lock-Dir $dir
    Copy-Item (Join-Path $PSScriptRoot "spike-boot.ps1") (Join-Path $dir "spike-boot.ps1") -Force
    if ($rootfsOrigen) { Copy-Item $rootfsOrigen (Join-Path $dir "alpine.tar.gz") -Force }
    $cfg = @{ RabbitHostPort = @($RabbitHostPort); ProbarWsl = [bool]$ProbarWsl; Minutos = $Minutos } | ConvertTo-Json
    Set-Content -Path (Join-Path $dir "config.json") -Value $cfg
    Lock-Dir $dir   # re-aplica la ACL a lo recien copiado
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$dir\spike-boot.ps1`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "Tarea '$task' creada (SYSTEM, al iniciar el sistema). Carpeta bloqueada: $dir"
    Write-Host "Siguiente: APAGA el equipo (Apagar, no Reiniciar), enciendelo a mano y NO inicies sesion ~10 min. Ver LEEME-SPIKE.txt."
    return
}

if ($EjecutarAhora) {
    Need-Admin
    Start-ScheduledTask -TaskName $task
    Write-Host "Disparada. Espera 1-2 min y corre -Estado."
    return
}

if ($Quitar) {
    Need-Admin
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    $q = Join-Path $dir "quitar.log"
    if (Test-Path (Join-Path $dir "spike-boot.ps1")) {
        Remove-Item $q -Force -ErrorAction SilentlyContinue
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$dir\spike-boot.ps1`" -Quitar"
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $taskQuitar -Action $action -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $taskQuitar
        $t0 = Get-Date
        while (((Get-Date) - $t0).TotalSeconds -lt 180) {
            if ((Test-Path $q) -and (Select-String -Path $q -Pattern "FIN-QUITAR" -Quiet)) { break }
            Start-Sleep -Seconds 3
        }
        Unregister-ScheduledTask -TaskName $taskQuitar -Confirm:$false -ErrorAction SilentlyContinue
        if (Test-Path $q) { Get-Content $q } else { Write-Host "ATENCION: la tarea de limpieza no escribio quitar.log." -ForegroundColor Yellow }
        if (-not ((Test-Path $q) -and (Select-String -Path $q -Pattern "RESULTADO: LIMPIO" -Quiet))) {
            Write-Host "NO se borra la carpeta porque la verificacion no dio LIMPIO. Revisa $q" -ForegroundColor Yellow
            return
        }
    } else {
        Write-Host "No hay carpeta del spike; nada que quitar."
    }
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Spike eliminado (tarea, distro WSL, procesos y carpeta)."
    return
}
Write-Host "Usa -Instalar, -EjecutarAhora, -Estado o -Quitar (ver Get-Help)."
