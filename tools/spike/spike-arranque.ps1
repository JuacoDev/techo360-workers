<#
.SYNOPSIS
    Spike de "arranque sin sesion" (fase S). NO toca produccion: no se conecta a RabbitMQ con login,
    no registra consumers, no modifica Docker ni el Ollama normal del usuario.

.DESCRIPTION
    -Instalar : (admin) crea la tarea programada "Techo360Spike" que corre como SYSTEM AL INICIAR EL
                SISTEMA (no al iniciar sesion) y ejecuta spike-boot.ps1. Copia todo a
                %ProgramData%\Techo360Spike\. Con -ProbarWsl descarga un rootfs minimo de Alpine
                (3.5 MB) para probar "wsl --import" ejecutado como SYSTEM.
    -Quitar   : (admin) borra la tarea, apaga lo que haya arrancado el spike y elimina la carpeta
                (con -ConservarLog deja boot.log).
    -Estado   : lee boot.log (no requiere admin).
    -EjecutarAhora : (admin) dispara la tarea ya, sin reiniciar, para validar que SYSTEM puede
                hacer cada cosa (el "sin sesion" real solo se demuestra reiniciando).

    Protocolo del reinicio: ver el informe de la fase S.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\spike-arranque.ps1 -Instalar -ProbarWsl
#>
param(
    [switch]$Instalar,
    [switch]$Quitar,
    [switch]$Estado,
    [switch]$EjecutarAhora,
    [switch]$ProbarWsl,
    [switch]$ConservarLog,
    [string]$RabbitHostPort = "100.116.197.118:5672"
)
$ErrorActionPreference = "Stop"
$dir = Join-Path $env:ProgramData "Techo360Spike"
$task = "Techo360Spike"
$log = Join-Path $dir "boot.log"

function Need-Admin {
    $a = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $a) { throw "Ejecuta esta accion en PowerShell como Administrador." }
}

if ($Estado) {
    if (Test-Path $log) { Get-Content $log } else { Write-Host "Sin boot.log en $dir" }
    return
}

if ($Instalar) {
    Need-Admin
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item (Join-Path $PSScriptRoot "spike-boot.ps1") (Join-Path $dir "spike-boot.ps1") -Force
    $cfg = @{ RabbitHostPort = $RabbitHostPort; ProbarWsl = [bool]$ProbarWsl; Minutos = 20 } | ConvertTo-Json
    Set-Content -Path (Join-Path $dir "config.json") -Value $cfg
    if ($ProbarWsl) {
        $tar = Join-Path $dir "alpine.tar.gz"
        if (-not (Test-Path $tar)) {
            Invoke-WebRequest -UseBasicParsing "https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-minirootfs-3.20.3-x86_64.tar.gz" -OutFile $tar
        }
    }
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$dir\spike-boot.ps1`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "Tarea '$task' creada (SYSTEM, al iniciar el sistema). Carpeta: $dir"
    Write-Host "Ahora: reinicia, NO inicies sesion durante ~10 min, luego inicia y corre -Estado."
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
    Get-CimInstance Win32_Process -Filter "Name='ollama.exe'" | Where-Object { $_.CommandLine -match 'Techo360Spike|11435' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    & wsl.exe --terminate techo360spike 2>$null | Out-Null
    & wsl.exe --unregister techo360spike 2>$null | Out-Null
    if ($ConservarLog -and (Test-Path $log)) {
        Copy-Item $log (Join-Path $env:TEMP "techo360spike-boot.log") -Force
        Write-Host "Log copiado a $env:TEMP\techo360spike-boot.log"
    }
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Spike eliminado."
    return
}
Write-Host "Usa -Instalar, -EjecutarAhora, -Estado o -Quitar (ver Get-Help)."
