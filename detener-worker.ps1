$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
docker compose -f docker-compose.worker.yml stop chatbot-worker
if ($LASTEXITCODE -ne 0) { throw "No se pudo detener el worker." }