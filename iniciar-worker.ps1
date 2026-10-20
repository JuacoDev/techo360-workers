param([switch]$Construir)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

if ($Construir -or -not (docker image inspect "techo360-worker-chatbot:v0.4.1-testing" 2>$null)) {
    & .\build-worker-image.ps1
    if ($LASTEXITCODE -ne 0) { throw "No se pudo construir la imagen del worker." }
}

docker compose -f docker-compose.worker.yml up -d chatbot-worker
if ($LASTEXITCODE -ne 0) { throw "No se pudo arrancar el worker." }
docker logs --tail 80 techo360-worker-chatbot 2>&1 | Select-String 'contrato_max|Consumidor de|OLLAMA|ERROR|WARNING'