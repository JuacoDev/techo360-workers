<#
.SYNOPSIS
    ESQUELETO del vigilante del worker (una pasada; la tarea de SYSTEM lo lanza cada 3 min al iniciar el sistema).
    Por defecto SOLO DIAGNOSTICA (las acciones se registran como "simulada"); -Aplicar las ejecuta.
    No hay instalador todavia: las acciones reales (iniciar motor, reiniciar worker) son ganchos a completar
    cuando se elija el camino (WSL2+Docker Engine o nativo).

.DESCRIPTION
    Orden de comprobaciones: motor -> Tailscale (solo si la config lo pide) -> host alcanzable de RABBITMQ_HOSTS
    -> consumer sano. ACCESS_REFUSED => estado CREDENCIALES y NO se reinicia (reiniciar no arregla una password).
    Un solo vigilante a la vez (mutex global). Salida: logs\watchdog.log (rotado), estado.json y, solo en
    cambios de estado, el Registro de Eventos (fuente "Techo360Worker").

    Config (JSON, sin secretos) en -Config:
      { "Hosts": "10.154.12.191,100.116.197.118", "Tailscale": false, "Contenedor": "techo360-worker-chatbot" }

.PARAMETER Sondas
    Hashtable de scriptblocks para pruebas: Motor, Tailscale, Consumer, Host (todos opcionales).
#>
param(
    [string]$Config = (Join-Path $env:ProgramData "Techo360Worker\worker.config.json"),
    [string]$Dir = (Join-Path $env:ProgramData "Techo360Worker"),
    [switch]$Aplicar,
    [switch]$NoEventLog,
    [hashtable]$Sondas = @{}
)
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "Techo360Worker.psm1") -Force

$logPath = Join-Path $Dir "logs\watchdog.log"
$estadoPath = Join-Path $Dir "estado.json"
function Log([string]$m) { Write-RotatingLog -Path $logPath -Message $m }

# Un solo vigilante a la vez
$creado = $false
$mutex = New-Object System.Threading.Mutex($false, "Global\Techo360WorkerVigilante", [ref]$creado)
if (-not $mutex.WaitOne(0)) { Log "Otra instancia del vigilante esta corriendo; se sale."; return }
try {
    $cfg = Get-Content $Config -Raw | ConvertFrom-Json
    $contenedor = if ($cfg.PSObject.Properties["Contenedor"]) { $cfg.Contenedor } else { "techo360-worker-chatbot" }
    $previo = if (Test-Path $estadoPath) { Get-Content $estadoPath -Raw | ConvertFrom-Json } else { $null }
    $fallos = if ($previo) { [int]$previo.FallosConsecutivos } else { 0 }

    # ---- sondas (reemplazables en pruebas) ----
    $motor = if ($Sondas.ContainsKey("Motor")) { [bool](& $Sondas.Motor) } else {
        $null = & docker version --format '{{.Server.Version}}' 2>$null; ($LASTEXITCODE -eq 0) }
    $ts = $null
    if ($cfg.PSObject.Properties["Tailscale"] -and $cfg.Tailscale) {
        $ts = if ($Sondas.ContainsKey("Tailscale")) { [bool](& $Sondas.Tailscale) } else { (Get-Service Tailscale -ErrorAction SilentlyContinue).Status -eq "Running" }
    }
    $hostElegido = if ($Sondas.ContainsKey("Host")) { & $Sondas.Host } else { Select-RabbitHost -Hosts $cfg.Hosts }
    $consumer = if ($Sondas.ContainsKey("Consumer")) { & $Sondas.Consumer } elseif (-not $motor) { "desconocido" } else {
        # HIPOTESIS / no verificado en labs: los patrones de perdida/recuperacion salen del log real del consumer
        # (aio-pika: "Connection to amqp://... closed. Reconnecting"; arranque: "Consumidor de 'chatbot_requests' arrancado").
        $log = (& docker logs --since 10m --tail 300 $contenedor 2>&1 | Out-String)
        $salud = (& docker inspect $contenedor --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>$null)
        if ($log -match "ACCESS_REFUSED") { "credenciales" }
        elseif ($salud -eq "unhealthy") { "caido" }
        elseif ($log -match "Reconnecting after" -and $log -notmatch "arrancado") { "caido" }
        elseif ($salud -in "healthy", "none") { "sano" } else { "desconocido" }
    }

    $estado = Get-EstadoWorker -Motor $motor -Tailscale $ts -HostElegido $hostElegido -Consumer $consumer
    $accion = Get-AccionPorEstado -Estado $estado
    $fallos = if ($estado -eq "OK") { 0 } else { $fallos + 1 }
    $hostTxt = if ($hostElegido) { "$($hostElegido.Host):$($hostElegido.Port)" } else { "ninguno" }
    Log "estado=$estado host=$hostTxt consumer=$consumer fallos=$fallos accion=$accion"

    if ($accion -ne "ninguna" -and (Test-DebeReintentar -FallosConsecutivos $fallos)) {
        if ($Aplicar) {
            # GANCHOS A COMPLETAR segun el camino elegido (S): iniciar motor / servicio Tailscale / reiniciar contenedor.
            Log "ACCION $accion : gancho no implementado todavia (esqueleto)"
        } else { Log "ACCION $accion (simulada: falta -Aplicar)" }
    } elseif ($accion -ne "ninguna") { Log "ACCION $accion omitida por backoff (fallos=$fallos)" }

    # Registro de Eventos SOLO si cambia el estado
    if ((-not $previo) -or $previo.Estado -ne $estado) {
        Log "CAMBIO DE ESTADO: $(if ($previo) { $previo.Estado } else { '(inicio)' }) -> $estado"
        if (-not $NoEventLog) {
            try {
                if (-not [System.Diagnostics.EventLog]::SourceExists("Techo360Worker")) { New-EventLog -LogName Application -Source "Techo360Worker" }
                $tipo = if ($estado -eq "OK") { "Information" } else { "Warning" }
                Write-EventLog -LogName Application -Source "Techo360Worker" -EventId 100 -EntryType $tipo -Message "Worker Techo360: estado $estado (host $hostTxt)."
            } catch { Log "No se pudo escribir en el Registro de Eventos: $($_.Exception.Message)" }
        }
    }
    @{ Estado = $estado; Host = $hostTxt; Consumer = $consumer; FallosConsecutivos = $fallos; Actualizado = (Get-Date -Format "s") } |
        ConvertTo-Json | Set-Content -Path $estadoPath
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
