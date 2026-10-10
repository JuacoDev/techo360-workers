# Techo360Worker.psm1 - piezas comunes del instalador y del vigilante (compatibles con PowerShell 5.1).
# No contiene logica de instalacion. Reglas que implementa:
#   - Seleccion de host de RabbitMQ: primero alcanzable de una lista (RABBITMQ_HOSTS).
#   - Contrasena: SecureString -> DPAPI LocalMachine -> archivo bajo una carpeta con ACL SYSTEM/Administradores.
#     Nunca en .env, compose, logs, .exe, MANIFEST ni paquete.
#   - Verificacion de que la cadena secreta no aparece en ningun lado (devuelve SOLO ubicaciones, nunca el valor).
#   - Estados del vigilante y log rotado.
Set-StrictMode -Version 2
Add-Type -AssemblyName System.Security

$script:DpapiEntropy = [System.Text.Encoding]::UTF8.GetBytes("techo360-worker/v1")

# ============================================================ (a) host de RabbitMQ
function Get-RabbitHostList {
    # "10.154.12.191,100.116.197.118:5673" -> objetos Host/Port en el MISMO orden (el orden es la preferencia).
    param([Parameter(Mandatory)][string]$Hosts, [int]$DefaultPort = 5672)
    $i = 0
    foreach ($h in ($Hosts -split '[,;\s]+' | Where-Object { $_ })) {
        $p = $DefaultPort; $name = $h
        if ($h -match '^(?<h>[^:]+):(?<p>\d+)$') { $name = $Matches['h']; $p = [int]$Matches['p'] }
        [pscustomobject]@{ Orden = $i; Host = $name; Port = $p }
        $i++
    }
}

function Test-TcpPort {
    param([Parameter(Mandatory)][string]$ComputerName, [Parameter(Mandatory)][int]$Port, [int]$TimeoutMs = 3000)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($ComputerName, $Port, $null, $null)
        return ($iar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $c.Connected)
    } catch { return $false } finally { $c.Close() }
}

function Select-RabbitHost {
    # Devuelve el primer host alcanzable (objeto Host/Port/Orden) o $null. $Probe es inyectable para pruebas.
    param(
        [Parameter(Mandatory)][string]$Hosts, [int]$DefaultPort = 5672, [int]$TimeoutMs = 3000,
        [scriptblock]$Probe = { param($h, $p, $t) Test-TcpPort -ComputerName $h -Port $p -TimeoutMs $t }
    )
    foreach ($h in (Get-RabbitHostList -Hosts $Hosts -DefaultPort $DefaultPort)) {
        if (& $Probe $h.Host $h.Port $TimeoutMs) { return $h }
    }
    return $null
}

# ============================================================ (b) ACL + DPAPI
function Set-LockedAcl {
    # Carpeta desde la que SYSTEM ejecuta codigo o guarda secretos: solo SYSTEM y Administradores (SIDs, no nombres).
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"   # icacls escribe avisos en stderr
    try { & icacls.exe $Path /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" /T /C 2>&1 | Out-Null } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { throw "icacls no pudo bloquear $Path (exit $LASTEXITCODE)." }
}

function Protect-WorkerSecret {
    # SecureString -> DPAPI LocalMachine -> $Path. Con -Bloquear (por defecto) la carpeta queda con ACL restringida
    # ANTES de escribir; eso exige ejecutar como administrador.
    param([Parameter(Mandatory)][System.Security.SecureString]$Secret, [Parameter(Mandatory)][string]$Path, [bool]$Bloquear = $true)
    $dir = Split-Path $Path -Parent
    if ($Bloquear) { Set-LockedAcl -Path $dir } else { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $bstr = [IntPtr]::Zero; $chars = $null; $bytes = $null
    try {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
        $chars = New-Object char[] $Secret.Length
        [System.Runtime.InteropServices.Marshal]::Copy($bstr, $chars, 0, $Secret.Length)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($chars)
        $cifrado = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $script:DpapiEntropy, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        [System.IO.File]::WriteAllBytes($Path, $cifrado)
    } finally {
        if ($bstr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if ($chars) { [Array]::Clear($chars, 0, $chars.Length) }
        if ($bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function Get-WorkerSecret {
    # Descifra a SecureString (en memoria). DPAPI LocalMachine lo descifra cualquier proceso del equipo: lo que
    # protege el archivo es la ACL de la carpeta, no el cifrado (ver modelo de amenazas en el README).
    param([Parameter(Mandatory)][string]$Path)
    $cifrado = [System.IO.File]::ReadAllBytes($Path)
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($cifrado, $script:DpapiEntropy, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    $ss = New-Object System.Security.SecureString
    try {
        foreach ($c in [System.Text.Encoding]::UTF8.GetChars($bytes)) { $ss.AppendChar($c) }
        $ss.MakeReadOnly()
        return $ss
    } finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Use-WorkerSecretEnv {
    # Pone el secreto en una variable de entorno SOLO del proceso, ejecuta el bloque y la borra. Nunca por linea de
    # comandos. Si el bloque pasa la variable a un contenedor (docker compose), `docker inspect` la mostrara a quien
    # pueda hablar con Docker: minimizar ese acceso (admins / docker-users).
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$EnvName, [Parameter(Mandatory)][scriptblock]$Block)
    $ss = Get-WorkerSecret -Path $Path
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try {
        [Environment]::SetEnvironmentVariable($EnvName, [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr), "Process")
        & $Block
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        [Environment]::SetEnvironmentVariable($EnvName, $null, "Process")
    }
}

function Find-SecretLeak {
    # Busca la cadena secreta en archivos, entorno, historial de PowerShell, Registro de Eventos, tareas programadas
    # y `docker inspect`. DEVUELVE SOLO UBICACIONES (cadenas descriptivas), nunca el valor ni fragmentos.
    param(
        [Parameter(Mandatory)][System.Security.SecureString]$Secret,
        [string[]]$Path = @(),
        [switch]$Entorno, [switch]$HistorialPS, [switch]$EventLog, [switch]$Tareas, [switch]$DockerInspect,
        [int]$MaxEventos = 3000, [long]$MaxBytesArchivo = 200MB
    )
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        if ([string]::IsNullOrEmpty($plain)) { throw "Secreto vacio." }
        $pat8 = $latin1.GetString([System.Text.Encoding]::UTF8.GetBytes($plain))
        $pat16 = $latin1.GetString([System.Text.Encoding]::Unicode.GetBytes($plain))
        $hallazgos = New-Object System.Collections.Generic.List[string]

        foreach ($raiz in $Path) {
            if (-not (Test-Path $raiz)) { continue }
            foreach ($f in (Get-ChildItem -LiteralPath $raiz -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                if ($f.Length -gt $MaxBytesArchivo) { $hallazgos.Add("OMITIDO(>tam): $($f.FullName)"); continue }
                try {
                    $txt = $latin1.GetString([System.IO.File]::ReadAllBytes($f.FullName))
                    if ($txt.IndexOf($pat8, [StringComparison]::Ordinal) -ge 0 -or $txt.IndexOf($pat16, [StringComparison]::Ordinal) -ge 0) { $hallazgos.Add("ARCHIVO: $($f.FullName)") }
                } catch { $hallazgos.Add("ILEGIBLE: $($f.FullName)") }
            }
        }
        if ($Entorno) {
            foreach ($ambito in "Machine", "User", "Process") {
                $vars = [Environment]::GetEnvironmentVariables($ambito)
                foreach ($k in $vars.Keys) { if ("$($vars[$k])".IndexOf($plain, [StringComparison]::Ordinal) -ge 0) { $hallazgos.Add("ENTORNO($ambito): variable $k") } }
            }
        }
        if ($HistorialPS) {
            foreach ($h in (Get-ChildItem "C:\Users\*\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\*.txt" -ErrorAction SilentlyContinue)) {
                if ((Get-Content -LiteralPath $h.FullName -Raw -ErrorAction SilentlyContinue) -and (Get-Content -LiteralPath $h.FullName -Raw).IndexOf($plain, [StringComparison]::Ordinal) -ge 0) { $hallazgos.Add("HISTORIAL-PS: $($h.FullName)") }
            }
        }
        if ($EventLog) {
            foreach ($log in "Application", "System", "Windows PowerShell", "Microsoft-Windows-PowerShell/Operational", "Microsoft-Windows-TaskScheduler/Operational") {
                try {
                    foreach ($e in (Get-WinEvent -LogName $log -MaxEvents $MaxEventos -ErrorAction Stop)) {
                        if ($e.Message -and $e.Message.IndexOf($plain, [StringComparison]::Ordinal) -ge 0) { $hallazgos.Add("EVENTLOG: $log id=$($e.Id) $($e.TimeCreated.ToString('s'))") }
                    }
                } catch { }
            }
        }
        if ($Tareas) {
            foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
                $xml = try { Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop } catch { "" }
                if ($xml.IndexOf($plain, [StringComparison]::Ordinal) -ge 0) { $hallazgos.Add("TAREA: $($t.TaskPath)$($t.TaskName)") }
            }
        }
        if ($DockerInspect -and (Get-Command docker -ErrorAction SilentlyContinue)) {
            foreach ($id in @(docker ps -aq 2>$null)) {
                $ins = (docker inspect $id 2>$null | Out-String)
                if ($ins.IndexOf($plain, [StringComparison]::Ordinal) -ge 0) { $hallazgos.Add("DOCKER-INSPECT: contenedor $id (la variable de entorno del contenedor lo contiene)") }
            }
        }
        return $hallazgos.ToArray()
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $plain = $null; $pat8 = $null; $pat16 = $null
    }
}

# ============================================================ (c) log rotado, estados, backoff
function Write-RotatingLog {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Message, [long]$MaxBytes = 1MB, [int]$Keep = 5)
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if ((Test-Path $Path) -and (Get-Item $Path).Length -ge $MaxBytes) {
        if (Test-Path "$Path.$Keep") { Remove-Item "$Path.$Keep" -Force }
        for ($i = $Keep - 1; $i -ge 1; $i--) {
            if (Test-Path "$Path.$i") { Move-Item "$Path.$i" "$Path.$($i + 1)" -Force }
        }
        Move-Item $Path "$Path.1" -Force
    }
    Add-Content -Path $Path -Value ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message)
}

function Get-EstadoWorker {
    # Funcion pura: de las sondas al estado. Orden = prioridad del diagnostico.
    #   Motor: bool | Tailscale: $true/$false/$null (null = no requerido) | HostElegido: objeto o $null
    #   Consumer: 'sano' | 'caido' | 'credenciales' | 'desconocido'
    param([bool]$Motor, $Tailscale, $HostElegido, [string]$Consumer)
    if (-not $Motor) { return "MOTOR_CAIDO" }
    if ($null -ne $Tailscale -and -not $Tailscale) { return "TAILSCALE_CAIDO" }
    if (-not $HostElegido) { return "SIN_RUTA" }
    if ($Consumer -eq "credenciales") { return "CREDENCIALES" }     # ACCESS_REFUSED: NO reiniciar
    if ($Consumer -eq "caido") { return "CONSUMER_CAIDO" }
    if ($Consumer -eq "sano") { return "OK" }
    return "DESCONOCIDO"
}

function Get-AccionPorEstado {
    # Que haria el vigilante en cada estado. 'ninguna' = solo registrar y esperar.
    param([Parameter(Mandatory)][string]$Estado)
    switch ($Estado) {
        "MOTOR_CAIDO"     { "iniciar-motor" }
        "TAILSCALE_CAIDO" { "iniciar-tailscale" }
        "CONSUMER_CAIDO"  { "reiniciar-worker" }
        default           { "ninguna" }      # OK, SIN_RUTA (esperar la red), CREDENCIALES (nunca reiniciar), DESCONOCIDO
    }
}

function Test-DebeReintentar {
    # Backoff exponencial por ciclos (el vigilante corre cada 3 min): actua en el fallo 1, 2, 4, 8 y luego cada 10.
    param([Parameter(Mandatory)][int]$FallosConsecutivos, [int]$Tope = 10)
    if ($FallosConsecutivos -le 0) { return $false }
    if ($FallosConsecutivos -ge $Tope) { return ($FallosConsecutivos % $Tope) -eq 0 }
    return (($FallosConsecutivos -band ($FallosConsecutivos - 1)) -eq 0)   # potencia de 2
}

Export-ModuleMember -Function Get-RabbitHostList, Test-TcpPort, Select-RabbitHost, Set-LockedAcl, Protect-WorkerSecret, Get-WorkerSecret, Use-WorkerSecretEnv, Find-SecretLeak, Write-RotatingLog, Get-EstadoWorker, Get-AccionPorEstado, Test-DebeReintentar
