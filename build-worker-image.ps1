<#
.SYNOPSIS
    Construye la imagen del worker desde un SHA FIJADO de techo360-chatbot (git archive), no desde
    "lo que haya checked-out". Usa Dockerfile.worker + requirements-worker.txt (este repo).

.PARAMETER ChatbotSha
    Commit de techo360-chatbot. Por defecto a8a0128 (merge del PR #10 en Testing).

.PARAMETER Tag
    Tag de la imagen resultante.
#>
param(
    [string]$ChatbotSha = "a8a0128c1085d915a7191385e638e5f83ace7881",
    [string]$Tag = "techo360-worker-chatbot:v3.3-a8a0128",
    [string]$ChatbotRepo = (Join-Path (Split-Path $PSScriptRoot -Parent) "techo360-chatbot")
)
$ErrorActionPreference = "Stop"
if (-not (Test-Path (Join-Path $ChatbotRepo ".git"))) { throw "No es un repo git: $ChatbotRepo" }
$full = (& git -C $ChatbotRepo rev-parse --verify "$ChatbotSha^{commit}" 2>&1)
if ($LASTEXITCODE -ne 0) { throw "El commit $ChatbotSha no existe en $ChatbotRepo (haz git fetch)." }

$ctx = Join-Path $env:TEMP ("techo360-worker-ctx-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $ctx | Out-Null
try {
    $tar = Join-Path $ctx "app.tar"
    & git -C $ChatbotRepo archive --format=tar -o $tar $full app
    if ($LASTEXITCODE -ne 0) { throw "git archive fallo" }
    # tar de Windows explicitamente: el GNU tar de Git-Bash interpreta "C:" como un host remoto.
    & "$env:SystemRoot\System32\tar.exe" -xf $tar -C $ctx
    if ($LASTEXITCODE -ne 0) { throw "tar fallo extrayendo el archivo del SHA" }
    Remove-Item $tar
    Copy-Item (Join-Path $PSScriptRoot "Dockerfile.worker") $ctx
    Copy-Item (Join-Path $PSScriptRoot "requirements-worker.txt") $ctx
    & docker build -f (Join-Path $ctx "Dockerfile.worker") --build-arg "CHATBOT_SHA=$full" -t $Tag $ctx
    if ($LASTEXITCODE -ne 0) { throw "docker build fallo (exit $LASTEXITCODE)" }
} finally {
    Remove-Item $ctx -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Imagen $Tag construida desde $full"
