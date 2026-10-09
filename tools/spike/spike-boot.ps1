# Carga util del spike: corre como SYSTEM al arrancar. Solo escribe en boot.log de su carpeta.
# No se conecta a RabbitMQ con credenciales (solo prueba TCP y cierra), no toca Docker ni el Ollama
# normal del usuario (usa puerto 11435 y su propia carpeta de modelos).
$ErrorActionPreference = "Continue"
$dir = Join-Path $env:ProgramData "Techo360Spike"
$log = Join-Path $dir "boot.log"
$cfg = Get-Content (Join-Path $dir "config.json") -Raw | ConvertFrom-Json

function L([string]$m) { Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m) }
function Sesiones {
    # Sesiones interactivas/RDP reales (LogonType 2, 10, 11) + procesos explorer.exe
    $s = @(Get-CimInstance Win32_LogonSession | Where-Object { $_.LogonType -in 2, 10, 11 }).Count
    $e = @(Get-Process explorer -ErrorAction SilentlyContinue).Count
    "sesiones_interactivas=$s explorer=$e"
}
function Tcp([string]$hp) {
    $h, $p = $hp -split ":"
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect($h, [int]$p, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(3000) -and $c.Connected
        $c.Close()
        if ($ok) { "ALCANZABLE" } else { "timeout" }
    } catch { "error" }
}

$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
L "=== INICIO spike. Usuario=$(whoami) arranque_SO=$($boot.ToString('yyyy-MM-dd HH:mm:ss')) $(Sesiones)"

# --- (c) Ollama nativo como SYSTEM, puerto y modelos propios ---
$ollama = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
if (-not (Test-Path $ollama)) { $ollama = (Get-Command ollama -ErrorAction SilentlyContinue).Source }
if (-not $ollama) {
    # Instalacion por-usuario: buscar en perfiles
    $ollama = Get-ChildItem "C:\Users\*\AppData\Local\Programs\Ollama\ollama.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}
if ($ollama) {
    $env:OLLAMA_HOST = "127.0.0.1:11435"
    $env:OLLAMA_MODELS = Join-Path $dir "ollama-models"
    New-Item -ItemType Directory -Force -Path $env:OLLAMA_MODELS | Out-Null
    $p = Start-Process -FilePath $ollama -ArgumentList "serve" -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $dir "ollama.err.txt") -RedirectStandardOutput (Join-Path $dir "ollama.out.txt")
    L "ollama serve lanzado como SYSTEM pid=$($p.Id) exe=$ollama"
} else { L "ollama.exe NO encontrado para SYSTEM" }

# --- (b) WSL como SYSTEM ---
if ($cfg.ProbarWsl) {
    $wsl = "$env:SystemRoot\System32\wsl.exe"
    $out = (& $wsl -l -v 2>&1 | Out-String) -replace "`0", ""
    L ("wsl -l -v como SYSTEM: " + (($out -split "`r?`n" | Where-Object { $_.Trim() }) -join " | "))
    if ($out -notmatch "techo360spike") {
        $imp = (& $wsl --import techo360spike (Join-Path $dir "wsl") (Join-Path $dir "alpine.tar.gz") --version 2 2>&1 | Out-String) -replace "`0", ""
        L ("wsl --import como SYSTEM (exit $LASTEXITCODE): " + ($imp -replace "\s+", " ").Trim())
    }
    # Proceso de larga vida dentro de la distro, para que el VM de WSL no se apague sin sesion
    Start-Process -FilePath $wsl -ArgumentList "-d techo360spike -- sh -c `"sleep 100000`"" -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 10
    $e = (& $wsl -d techo360spike -- sh -c "echo wsl_vivo; uname -r" 2>&1 | Out-String) -replace "`0", ""
    L ("wsl exec como SYSTEM: " + ($e -replace "\s+", " ").Trim())
}

# --- Marcas cada 30 s ---
$fin = (Get-Date).AddMinutes([int]$cfg.Minutos)
$i = 0
while ((Get-Date) -lt $fin) {
    $i++
    $api = try { (Invoke-RestMethod -Uri "http://127.0.0.1:11435/api/version" -TimeoutSec 3).version } catch { "sin_respuesta" }
    $wslv = ""
    if ($cfg.ProbarWsl) { $wslv = " wsl_vivo=" + (((& "$env:SystemRoot\System32\wsl.exe" -d techo360spike -- sh -c "echo si" 2>&1 | Out-String) -replace "`0", "").Trim()) }
    L ("marca#$i $(Sesiones) rabbit_tcp=$(Tcp $cfg.RabbitHostPort) ollama_nativo_api=$api$wslv")
    Start-Sleep -Seconds 30
}
L "=== FIN spike (ventana de $($cfg.Minutos) min cumplida)"
