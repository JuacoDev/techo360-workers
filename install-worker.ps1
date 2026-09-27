<#
.SYNOPSIS
    Instalador del worker de chatbot de Techo 360 (validacion en PC propio).

.DESCRIPTION
    1. Verifica/instala Docker Desktop.
    2. Construye la imagen del worker (misma imagen de techo360-chatbot,
       sin modificar) e importa el modelo de Ollama de produccion.
    3. Genera el .env del worker con las credenciales de RabbitMQ.
    4. Arranca el contenedor.
    5. Verifica que el worker haya quedado conectado y consumiendo
       (log real del consumer, no solo "container running").

    El unico valor pensado para cambiar entre esta prueba y el despliegue
    final de laboratorio es -RabbitMqHost (hoy la IP de Tailscale del
    VPS; a futuro la IP privada de la universidad). Usuario/password de
    RabbitMQ son fijos para todo el pool de workers.

.PARAMETER RabbitMqHost
    Host/IP donde escucha RabbitMQ. Default: IP de Tailscale del VPS.

.PARAMETER RabbitMqUser
    Usuario de RabbitMQ exclusivo para workers (creado aparte, ver
    README.md -- NUNCA reusar las credenciales del chatbot del VPS).

.PARAMETER RabbitMqPassword
    Password de ese usuario, como SecureString (nunca en texto plano
    en el historial de PowerShell). Si se omite, se pide de forma
    interactiva.

.EXAMPLE
    .\install-worker.ps1 -RabbitMqHost 100.116.197.118 -RabbitMqUser techo360-worker
#>
param(
    [string]$RabbitMqHost = "100.116.197.118",
    [int]$RabbitMqPort = 5672,
    [string]$RabbitMqUser = "techo360-worker",
    [System.Security.SecureString]$RabbitMqPassword,
    [string]$OllamaModel = "techo360-chatbot:v3.2"
)

$ErrorActionPreference = "Stop"
# $PSScriptRoot no es confiable dentro de un .exe compilado con ps2exe
# -- se resuelve al ejecutable real (MainModule) en ese caso.
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Parent }
$ChatbotRepo = Join-Path (Split-Path $RepoRoot -Parent) "techo360-chatbot"

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

# Bajo ps2exe (a diferencia de correr el .ps1 suelto), la salida de
# progreso que docker/winget escriben en stderr se propaga como
# ErrorRecord de PowerShell -- con $ErrorActionPreference="Stop" eso
# aborta el script aunque el comando en realidad haya tenido exito
# (confirmado real: "Image ... Building" abortaba la instalacion desde
# el .exe compilado, nunca desde el .ps1 directo). Se corren los
# comandos nativos con esta funcion: preferencia de error local en
# Continue, y se revisa $LASTEXITCODE explicitamente en vez de confiar
# en el stream de error.
function Invoke-Native {
    # $ArgList, NO $Args -- ese nombre choca con la variable automatica
    # $args de PowerShell y se comporta distinto entre el .ps1 suelto y
    # el .exe compilado con ps2exe (confirmado real: bajo el .exe,
    # "docker" recibia cero argumentos y solo imprimia su ayuda general).
    param([string]$Exe, [string[]]$ArgList, [string]$ErrorMessage)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Exe @ArgList 2>&1 | ForEach-Object { Write-Host $_ }
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$ErrorMessage (exit code $LASTEXITCODE)"
    }
}

# ------------------------------------------------------------
# 1. Docker
# ------------------------------------------------------------
Write-Step "Verificando Docker"

$dockerBin = "C:\Program Files\Docker\Docker\resources\bin"
if (Test-Path (Join-Path $dockerBin "docker.exe")) {
    if ($env:PATH -notlike "*$dockerBin*") { $env:PATH += ";$dockerBin" }
}

$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCmd) {
    Write-Host "Docker no encontrado. Instalando Docker Desktop via winget..."
    Invoke-Native winget @("install", "--id", "Docker.DockerDesktop", "-e", "--accept-package-agreements", "--accept-source-agreements") "No se pudo instalar Docker Desktop con winget"
    throw "Docker Desktop se acaba de instalar: reinicia la maquina/terminal y vuelve a correr este script (el primer arranque de Docker Desktop requiere reinicio de sesion en Windows)."
}

$dockerVersion = docker version --format '{{.Server.Version}}' 2>$null
if (-not $dockerVersion) {
    throw "Docker esta instalado pero el motor no responde. Abre Docker Desktop manualmente, espera a que quede 'Running' y vuelve a correr este script."
}
Write-Host "Docker OK: $dockerVersion"

# ------------------------------------------------------------
# 2. Repo hermano techo360-chatbot (mismo codigo/imagen, sin tocarlo)
# ------------------------------------------------------------
Write-Step "Verificando repo techo360-chatbot"
if (-not (Test-Path $ChatbotRepo)) {
    throw "No se encontro '$ChatbotRepo'. Clona techo360-chatbot como repo hermano de techo360-workers antes de continuar (mismo patron que techo360-infra usa con sus servicios)."
}
Write-Host "Encontrado: $ChatbotRepo"

# ------------------------------------------------------------
# 3-4. .env: si ya viene generado junto al instalador (caso normal de
# laboratorio -- credenciales fijas para todo el pool), se usa tal
# cual y no se pide nada. Solo se pregunta la password si hace falta
# generarlo de cero (ej. primera vez en una maquina nueva sin .env).
# ------------------------------------------------------------
$envPath = Join-Path $RepoRoot ".env"
if (Test-Path $envPath) {
    Write-Step ".env existente detectado, se usa tal cual"
    Write-Host "Encontrado: $envPath (no se pide password, no se modifica)"
} else {
    Write-Step "Generando .env"
    if (-not $RabbitMqPassword) {
        $RabbitMqPassword = Read-Host -AsSecureString "Password del usuario RabbitMQ '$RabbitMqUser'"
    }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($RabbitMqPassword)
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

    $envContent = @"
RABBITMQ_HOST=$RabbitMqHost
RABBITMQ_PORT=$RabbitMqPort
RABBITMQ_USER=$RabbitMqUser
RABBITMQ_PASSWORD=$plainPassword
OLLAMA_MODEL=$OllamaModel
CHATBOT_CONSUMER_PRIORITY=10
"@
    Set-Content -Path $envPath -Value $envContent -NoNewline
    $plainPassword = $null
    Write-Host ".env generado en $envPath"
}

# ------------------------------------------------------------
# 5. Construir imagen y arrancar
# ------------------------------------------------------------
Write-Step "Construyendo imagen del worker (misma imagen de techo360-chatbot)"
Push-Location $RepoRoot
try {
    Invoke-Native docker @("compose", "-f", "docker-compose.worker.yml", "build") "Fallo el build de la imagen del worker"
    Invoke-Native docker @("compose", "-f", "docker-compose.worker.yml", "up", "-d", "ollama") "Fallo al arrancar el contenedor de Ollama"
} finally {
    Pop-Location
}

# ------------------------------------------------------------
# 6. Importar el modelo de produccion en el Ollama del worker
# ------------------------------------------------------------
Write-Step "Importando modelo $OllamaModel en el Ollama del worker"
$modelfilePath = Join-Path $ChatbotRepo "training\ollama\Modelfile.v3.2"
# El GGUF ya NO vive en techo360-chatbot (limpieza 27-sep-2026: ese repo
# solo conserva codigo/metricas, no los ~38G de artefactos de
# entrenamiento) -- vive junto al instalador, en models/, sin trackear
# por git (ver .gitignore, demasiado pesado para el historial).
$ggufPath = Join-Path $RepoRoot "models\techo360-v3.2-Q4_K_M.gguf"
if (-not (Test-Path $modelfilePath) -or -not (Test-Path $ggufPath)) {
    throw "No se encontraron $modelfilePath / $ggufPath. Este PC necesita el GGUF de produccion en techo360-workers/models/ para poder responder con el mismo modelo -- no se distribuye por git."
}
Invoke-Native docker @("cp", $ggufPath, "techo360-worker-ollama:/tmp/techo360-v3.2-Q4_K_M.gguf") "Fallo copiando el GGUF al contenedor de Ollama"

# Copiamos el Modelfile REAL del repo (no lo reconstruimos inline) y solo
# reescribimos la linea FROM para que apunte a la ruta dentro del
# contenedor -- asi el system prompt/parametros quedan garantizados
# identicos al de techo360-chatbot/training/ollama/Modelfile.v3.2, sin
# duplicar ese texto (y su quoting) aqui.
$localModelfileCopy = Join-Path $env:TEMP "techo360-worker-Modelfile.v3.2"
(Get-Content $modelfilePath -Raw) -replace [regex]::Escape("FROM ../modelo_gguf/techo360-v3.2-Q4_K_M.gguf"), "FROM /tmp/techo360-v3.2-Q4_K_M.gguf" |
    Set-Content -Path $localModelfileCopy -NoNewline
Invoke-Native docker @("cp", $localModelfileCopy, "techo360-worker-ollama:/tmp/Modelfile.v3.2") "Fallo copiando el Modelfile al contenedor de Ollama"
Invoke-Native docker @("exec", "techo360-worker-ollama", "ollama", "create", $OllamaModel, "-f", "/tmp/Modelfile.v3.2") "Fallo 'ollama create' importando el modelo"

# ------------------------------------------------------------
# 7. Arrancar el worker del chatbot
# ------------------------------------------------------------
Write-Step "Arrancando el worker del chatbot"
Push-Location $RepoRoot
try {
    Invoke-Native docker @("compose", "-f", "docker-compose.worker.yml", "up", "-d", "chatbot-worker") "Fallo al arrancar el contenedor del worker"
} finally {
    Pop-Location
}

# ------------------------------------------------------------
# 8. Verificacion REAL de conexion (no solo "running")
# ------------------------------------------------------------
Write-Step "Verificando conexion real a RabbitMQ (log del consumer)"
Start-Sleep -Seconds 8
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$logs = docker logs techo360-worker-chatbot 2>&1 | Out-String
$ErrorActionPreference = $prevEap
if ($logs -match "ACCESS_REFUSED") {
    Write-Host $logs
    throw "RabbitMQ rechazo un permiso del usuario '$RabbitMqUser' (ACCESS_REFUSED). Revisa techo360-infra/scripts/rabbitmq-worker-user.sh -- los permisos deben cubrir chatbot_requests, chatbot_eventos_persistencia y el exchange 'amq.default' (respuesta RPC via reply_to)."
}
if ($logs -match "Consumidor de 'chatbot_requests' arrancado \(x-priority=10\)") {
    Write-Host "CONECTADO: el consumer confirmo arranque con prioridad 10." -ForegroundColor Green
} else {
    Write-Host "No se encontro la confirmacion de arranque en los logs. Salida completa:" -ForegroundColor Yellow
    Write-Host $logs
    throw "El worker no confirmo conexion/consumo real. Revisa RABBITMQ_HOST/usuario/password en .env y que el puerto 5672 este alcanzable (prueba: Test-NetConnection $RabbitMqHost -Port $RabbitMqPort)."
}

Write-Host "`nInstalacion completa. El worker esta corriendo y consumiendo de 'chatbot_requests' con prioridad alta." -ForegroundColor Green
