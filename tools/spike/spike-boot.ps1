# Carga util del spike: corre como SYSTEM. Solo escribe en su carpeta (ACL: SYSTEM y Administradores).
# No se conecta a RabbitMQ con credenciales (solo prueba TCP y cierra), no toca Docker, no instala nada.
# Si faltan ollama.exe o wsl.exe, lo registra y sigue.
param([switch]$Quitar)
$ErrorActionPreference = "Continue"
$dir = Join-Path $env:ProgramData "Techo360Spike"
$log = Join-Path $dir "boot.log"
$pidFile = Join-Path $dir "pids.json"
$wsl = "$env:SystemRoot\System32\wsl.exe"
function Sin-Nulos($t) { ($t | Out-String) -replace "`0", "" }
function Linea($t) { ((Sin-Nulos $t) -split "`r?`n" | Where-Object { $_.Trim() }) -join " | " }

# ------------------------------------------------------------------ modo -Quitar (tarea unica)
if ($Quitar) {
    $q = Join-Path $dir "quitar.log"
    function Q([string]$m) { Add-Content -Path $q -Value ("{0} {1}" -f (Get-Date -Format "HH:mm:ss"), $m) }
    Q "whoami=$(whoami)"
    # 1) procesos registrados por pid (nunca por nombre de imagen)
    if (Test-Path $pidFile) {
        $pids = Get-Content $pidFile -Raw | ConvertFrom-Json
        foreach ($e in @($pids)) {
            $p = Get-Process -Id $e.Pid -ErrorAction SilentlyContinue
            if ($p -and $p.ProcessName -eq $e.Nombre -and $p.StartTime.ToString("o") -eq $e.Inicio) { Stop-Process -Id $e.Pid -Force; Q "detenido pid=$($e.Pid) ($($e.Nombre))" }
            else { Q "pid=$($e.Pid) ($($e.Nombre)) ya no existe" }
        }
    }
    # 2) distro WSL registrada por SYSTEM
    if (Test-Path $wsl) {
        Q ("wsl -l -v ANTES: " + (Linea (& $wsl -l -v 2>&1)))
        & $wsl --terminate techo360spike 2>&1 | Out-Null
        $u = Sin-Nulos (& $wsl --unregister techo360spike 2>&1)
        Q ("wsl --unregister: " + ($u -replace "\s+", " ").Trim())
        # Apaga la VM de WSL de SYSTEM (cada usuario tiene la suya; esto no afecta a otros usuarios).
        # Solo como SYSTEM: ejecutado como usuario normal apagaria SU WSL (y el motor de Docker Desktop).
        if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { & $wsl --shutdown 2>&1 | Out-Null } else { Q "AVISO: no es SYSTEM; se omite wsl --shutdown (prueba parcial)" }
        Start-Sleep -Seconds 3
        $despues = Sin-Nulos (& $wsl -l -v 2>&1)
        $corriendo = Sin-Nulos (& $wsl -l --running 2>&1)
        Q ("wsl -l -v DESPUES: " + (Linea $despues))
        Q ("wsl -l --running DESPUES: " + (Linea $corriendo))
        $registro = $despues -match "techo360spike"
        $corriendoAlguna = [bool]($corriendo -match "techo360spike")
    } else { Q "wsl.exe no presente: nada que desregistrar"; $registro = $false; $corriendoAlguna = $false }
    # 3) procesos remanentes: ollama de esta carpeta y wsl.exe que mencionen la distro
    $resto = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -in "ollama.exe", "wsl.exe" -and $_.CommandLine -match "techo360spike|Techo360Spike" -and $_.ProcessId -ne $PID })
    foreach ($r in $resto) { Q "PROCESO REMANENTE pid=$($r.ProcessId) $($r.Name)" }
    # vmmem/vmmemWSL es solo informativo: no se distingue la VM de SYSTEM de la de otros usuarios.
    $vm = @(Get-Process vmmemWSL, vmmem -ErrorAction SilentlyContinue).Count
    Q "vmmem/vmmemWSL en el equipo (informativo, incluye VMs de otros usuarios): $vm"
    if ($registro -or $resto.Count -gt 0 -or $corriendoAlguna) { Q "RESULTADO: QUEDAN RESTOS" } else { Q "RESULTADO: LIMPIO" }
    Q "FIN-QUITAR"
    return
}

# ------------------------------------------------------------------ modo normal (al iniciar el sistema)
$cfg = Get-Content (Join-Path $dir "config.json") -Raw | ConvertFrom-Json
function L([string]$m) { Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m) }
function Sesiones {
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
$registrados = New-Object System.Collections.Generic.List[object]
function Registrar($proc) { if ($proc) { $registrados.Add(@{ Pid = $proc.Id; Nombre = $proc.ProcessName; Inicio = $proc.StartTime.ToString("o") }); ConvertTo-Json -InputObject @($registrados.ToArray()) | Set-Content $pidFile } }

# Arranque real: LastBootUpTime NO se reinicia con Inicio rapido; el evento Kernel-General 12 y el
# Kernel-Boot 27 (0 = arranque completo, 1 = Inicio rapido, 2 = reanudar de hibernacion) si.
$os = Get-CimInstance Win32_OperatingSystem
$fast = try { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction Stop).HiberbootEnabled } catch { "n/d" }
$ev12 = try { (Get-WinEvent -FilterHashtable @{ LogName = "System"; ProviderName = "Microsoft-Windows-Kernel-General"; Id = 12 } -MaxEvents 1 -ErrorAction Stop).TimeCreated.ToString("yyyy-MM-dd HH:mm:ss") } catch { "n/d" }
$ev27 = try { (Get-WinEvent -FilterHashtable @{ LogName = "System"; ProviderName = "Microsoft-Windows-Kernel-Boot"; Id = 27 } -MaxEvents 1 -ErrorAction Stop).Message -replace "\s+", " " } catch { "n/d" }
L "=== INICIO spike. Usuario=$(whoami) $(Sesiones)"
L "InicioRapido(HiberbootEnabled)=$fast  LastBootUpTime=$($os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss'))  arranque_real(Kernel-General12)=$ev12  Kernel-Boot27=[$ev27]"

# --- (c) Ollama nativo como SYSTEM, puerto y modelos propios; si no existe, se registra y se sigue ---
$ollama = (Get-Command ollama -ErrorAction SilentlyContinue).Source
if (-not $ollama) { $ollama = Get-ChildItem "C:\Users\*\AppData\Local\Programs\Ollama\ollama.exe", "C:\Program Files\Ollama\ollama.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
$ollamaProc = $null
if ($ollama) {
    $env:OLLAMA_HOST = "127.0.0.1:11435"
    $env:OLLAMA_MODELS = Join-Path $dir "ollama-models"
    New-Item -ItemType Directory -Force -Path $env:OLLAMA_MODELS | Out-Null
    $ollamaProc = Start-Process -FilePath $ollama -ArgumentList "serve" -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $dir "ollama.err.txt") -RedirectStandardOutput (Join-Path $dir "ollama.out.txt")
    Registrar $ollamaProc
    L "ollama serve lanzado como SYSTEM pid=$($ollamaProc.Id) exe=$ollama"
} else { L "ollama.exe no encontrado: se omite la prueba (c). No se instala nada." }

# --- (b) WSL como SYSTEM ---
$wslProc = $null
if ($cfg.ProbarWsl) {
    if (-not (Test-Path $wsl)) { L "wsl.exe NO existe en este equipo: prueba (b) imposible aqui." }
    else {
        $out = Sin-Nulos (& $wsl -l -v 2>&1)
        L ("wsl -l -v como SYSTEM: " + (($out -split "`r?`n" | Where-Object { $_.Trim() }) -join " | "))
        if ($out -notmatch "techo360spike") {
            $imp = Sin-Nulos (& $wsl --import techo360spike (Join-Path $dir "wsl") (Join-Path $dir "alpine.tar.gz") --version 2 2>&1)
            L ("wsl --import como SYSTEM (exit $LASTEXITCODE): " + ($imp -replace "\s+", " ").Trim())
        }
        $wslProc = Start-Process -FilePath $wsl -ArgumentList "-d techo360spike -- sh -c `"sleep 100000`"" -WindowStyle Hidden -PassThru
        Registrar $wslProc
        Start-Sleep -Seconds 10
        $e = Sin-Nulos (& $wsl -d techo360spike -- sh -c "echo wsl_vivo; uname -r" 2>&1)
        L ("wsl exec como SYSTEM: " + ($e -replace "\s+", " ").Trim())
    }
}

# --- Marcas cada 30 s ---
$fin = (Get-Date).AddMinutes([int]$cfg.Minutos)
$i = 0
while ((Get-Date) -lt $fin) {
    $i++
    $api = if ($ollamaProc) { try { (Invoke-RestMethod -Uri "http://127.0.0.1:11435/api/version" -TimeoutSec 3).version } catch { "sin_respuesta" } } else { "n/a" }
    $wslv = ""
    if ($cfg.ProbarWsl -and (Test-Path $wsl)) { $wslv = " wsl_vivo=" + ((Sin-Nulos (& $wsl -d techo360spike -- sh -c "echo si" 2>&1)).Trim()) }
    $red = (@($cfg.RabbitHostPort) | ForEach-Object { "$_=$(Tcp $_)" }) -join " "
    L ("marca#$i $(Sesiones) tcp: $red ollama_nativo_api=$api$wslv")
    Start-Sleep -Seconds 30
}
# Fin de ventana: se detienen los procesos propios (por pid). La distro WSL queda registrada hasta -Quitar.
foreach ($p in @($ollamaProc, $wslProc)) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
if ($cfg.ProbarWsl -and (Test-Path $wsl)) { & $wsl --terminate techo360spike 2>&1 | Out-Null }
L "=== FIN spike (ventana de $($cfg.Minutos) min cumplida; procesos propios detenidos)"
