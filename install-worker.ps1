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
$RepoRoot = $PSScriptRoot
$ChatbotRepo = Join-Path (Split-Path $RepoRoot -Parent) "techo360-chatbot"

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

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
    winget install --id Docker.DockerDesktop -e --accept-package-agreements --accept-source-agreements
    throw "Docker Desktop se acaba de instalar: reinicia la maquina/terminal y vuelve a correr este script (el primer arranque de Docker Desktop requiere reinicio de sesion en Windows)."
}

try {
    docker version --format '{{.Server.Version}}' | Out-Null
} catch {
    throw "Docker esta instalado pero el motor no responde. Abre Docker Desktop manualmente, espera a que quede 'Running' y vuelve a correr este script."
}
Write-Host "Docker OK: $(docker version --format '{{.Server.Version}}')"

# ------------------------------------------------------------
# 2. Repo hermano techo360-chatbot (mismo codigo/imagen, sin tocarlo)
# ------------------------------------------------------------
Write-Step "Verificando repo techo360-chatbot"
if (-not (Test-Path $ChatbotRepo)) {
    throw "No se encontro '$ChatbotRepo'. Clona techo360-chatbot como repo hermano de techo360-workers antes de continuar (mismo patron que techo360-infra usa con sus servicios)."
}
Write-Host "Encontrado: $ChatbotRepo"

# ------------------------------------------------------------
# 3. Password (nunca en texto plano en el historial)
# ------------------------------------------------------------
if (-not $RabbitMqPassword) {
    $RabbitMqPassword = Read-Host -AsSecureString "Password del usuario RabbitMQ '$RabbitMqUser'"
}
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($RabbitMqPassword)
$plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

# ------------------------------------------------------------
# 4. Generar .env (nunca se commitea, ver .gitignore)
# ------------------------------------------------------------
Write-Step "Generando .env"
$envContent = @"
RABBITMQ_HOST=$RabbitMqHost
RABBITMQ_PORT=$RabbitMqPort
RABBITMQ_USER=$RabbitMqUser
RABBITMQ_PASSWORD=$plainPassword
OLLAMA_MODEL=$OllamaModel
CHATBOT_CONSUMER_PRIORITY=10
"@
Set-Content -Path (Join-Path $RepoRoot ".env") -Value $envContent -NoNewline
$plainPassword = $null
Write-Host ".env generado en $RepoRoot\.env"

# ------------------------------------------------------------
# 5. Construir imagen y arrancar
# ------------------------------------------------------------
Write-Step "Construyendo imagen del worker (misma imagen de techo360-chatbot)"
Push-Location $RepoRoot
try {
    docker compose -f docker-compose.worker.yml build
    docker compose -f docker-compose.worker.yml up -d ollama
} finally {
    Pop-Location
}

# ------------------------------------------------------------
# 6. Importar el modelo de produccion en el Ollama del worker
# ------------------------------------------------------------
Write-Step "Importando modelo $OllamaModel en el Ollama del worker"
$modelfilePath = Join-Path $ChatbotRepo "training\ollama\Modelfile.v3.2"
$ggufPath = Join-Path $ChatbotRepo "training\modelo_gguf\techo360-v3.2-Q4_K_M.gguf"
if (-not (Test-Path $modelfilePath) -or -not (Test-Path $ggufPath)) {
    throw "No se encontraron $modelfilePath / $ggufPath. Este PC necesita el GGUF de produccion (training/modelo_gguf/) para poder responder con el mismo modelo -- no se distribuye por git (ver training/README.md de techo360-chatbot)."
}
docker cp $ggufPath techo360-worker-ollama:/tmp/techo360-v3.2-Q4_K_M.gguf
docker exec techo360-worker-ollama sh -c "printf 'FROM /tmp/techo360-v3.2-Q4_K_M.gguf\nSYSTEM \"Eres el asistente virtual de Techo 360, una plataforma que analiza la pobreza y el deficit de vivienda en los municipios de Colombia. Respondes en espanol de forma clara y precisa sobre el Score de Privacion y los indicadores de Techo 360, y sobre la politica publica colombiana de vivienda y pobreza (IPM, deficit habitacional, cobertura de acueducto y alcantarillado) en la que se basa el sistema.\"\nPARAMETER temperature 0.3\nPARAMETER top_p 0.9\nPARAMETER repeat_penalty 1.15\nPARAMETER num_ctx 2048\n' > /tmp/Modelfile.v3.2"
docker exec techo360-worker-ollama ollama create $OllamaModel -f /tmp/Modelfile.v3.2

# ------------------------------------------------------------
# 7. Arrancar el worker del chatbot
# ------------------------------------------------------------
Write-Step "Arrancando el worker del chatbot"
Push-Location $RepoRoot
try {
    docker compose -f docker-compose.worker.yml up -d chatbot-worker
} finally {
    Pop-Location
}

# ------------------------------------------------------------
# 8. Verificacion REAL de conexion (no solo "running")
# ------------------------------------------------------------
Write-Step "Verificando conexion real a RabbitMQ (log del consumer)"
Start-Sleep -Seconds 5
$logs = docker logs techo360-worker-chatbot 2>&1 | Out-String
if ($logs -match "Consumidor de 'chatbot_requests' arrancado \(x-priority=10\)") {
    Write-Host "CONECTADO: el consumer confirmo arranque con prioridad 10." -ForegroundColor Green
} else {
    Write-Host "No se encontro la confirmacion de arranque en los logs. Salida completa:" -ForegroundColor Yellow
    Write-Host $logs
    throw "El worker no confirmo conexion/consumo real. Revisa RABBITMQ_HOST/usuario/password en .env y que el puerto 5672 este alcanzable (prueba: Test-NetConnection $RabbitMqHost -Port $RabbitMqPort)."
}

Write-Host "`nInstalacion completa. El worker esta corriendo y consumiendo de 'chatbot_requests' con prioridad alta." -ForegroundColor Green
