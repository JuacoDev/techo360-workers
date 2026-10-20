param(
    [string]$Gguf = (Join-Path $env:USERPROFILE 'modelos\techo360-v0.4.1\techo360-v0.4.1-Q4_K_M.gguf'),
    [string]$Modelfile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'techo360-chatbot-wt-t41\training\ollama\Modelfile.v0.4.1')
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if (-not (Test-Path $Gguf)) { throw "No existe el GGUF: $Gguf" }
if (-not (Test-Path $Modelfile)) { throw "No existe el Modelfile: $Modelfile" }
docker compose -f docker-compose.worker.yml up -d ollama
if ($LASTEXITCODE -ne 0) { throw 'No se pudo iniciar Ollama GPU.' }
$tmp = Join-Path $env:TEMP ('Modelfile.v0.4.1.' + [guid]::NewGuid().ToString('N'))
try {
    $contenido = Get-Content $Modelfile -Raw
    $contenido = [regex]::Replace($contenido, '(?m)^FROM .+$', 'FROM /tmp/techo360-v0.4.1-Q4_K_M.gguf')
    [IO.File]::WriteAllText($tmp, $contenido, [Text.UTF8Encoding]::new($false))
    docker cp $Gguf techo360-worker-ollama:/tmp/techo360-v0.4.1-Q4_K_M.gguf
    docker cp $tmp techo360-worker-ollama:/tmp/Modelfile.v0.4.1
    docker exec techo360-worker-ollama ollama create techo360-chatbot:v0.4.1 -f /tmp/Modelfile.v0.4.1
    if ($LASTEXITCODE -ne 0) { throw 'ollama create fallo.' }
    docker exec techo360-worker-ollama ollama show techo360-chatbot:v0.4.1 --modelfile
} finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    docker exec techo360-worker-ollama rm -f /tmp/Modelfile.v0.4.1 /tmp/techo360-v0.4.1-Q4_K_M.gguf 2>$null
}