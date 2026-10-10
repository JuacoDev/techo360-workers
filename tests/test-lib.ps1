<#
Autoprueba de lib\Techo360Worker.psm1 y lib\vigilante.ps1. NO toca Docker, WSL, el worker ni produccion:
solo usa una carpeta temporal, sondas falsas y una cadena canario aleatoria que nunca se imprime.
Sin admin: se prueban todas las piezas salvo la escritura en una carpeta ya bloqueada (que exige admin).
Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-lib.ps1
#>
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "..\lib\Techo360Worker.psm1") -Force
$script:fallos = 0
function Ok([bool]$c, [string]$n) { if ($c) { Write-Host "  OK   $n" } else { Write-Host "  FALLA $n" -ForegroundColor Red; $script:fallos++ } }
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$tmp = Join-Path $env:TEMP ("t360test-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null

try {
    Write-Host "(a) seleccion de host"
    $l = @(Get-RabbitHostList -Hosts "10.154.12.191, 100.116.197.118:5673")
    Ok ($l.Count -eq 2 -and $l[0].Host -eq "10.154.12.191" -and $l[0].Port -eq 5672 -and $l[1].Port -eq 5673) "parseo de la lista y puertos"
    $sel = Select-RabbitHost -Hosts "10.1.1.1,10.2.2.2,10.3.3.3" -Probe { param($h, $p, $t) $h -ne "10.1.1.1" }
    Ok ($sel.Host -eq "10.2.2.2") "elige el PRIMER alcanzable respetando el orden"
    Ok ($null -eq (Select-RabbitHost -Hosts "10.1.1.1" -Probe { $false })) "ninguno alcanzable -> `$null"
    Ok (-not (Test-TcpPort -ComputerName "127.0.0.1" -Port 1 -TimeoutMs 500)) "Test-TcpPort real a puerto cerrado -> false"

    Write-Host "(b) DPAPI + ACL + busqueda de la cadena"
    $canario = "T360-" + [guid]::NewGuid().ToString("N")
    $ss = ConvertTo-SecureString $canario -AsPlainText -Force
    $dirSec = Join-Path $tmp "secreto"
    $dpapi = Join-Path $dirSec "rabbitmq.dpapi"
    Protect-WorkerSecret -Secret $ss -Path $dpapi -Bloquear $false
    $bytes = [IO.File]::ReadAllBytes($dpapi)
    $lat = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
    Ok ($lat.IndexOf($canario) -lt 0) "el archivo DPAPI no contiene la cadena en claro"
    $de = Get-WorkerSecret -Path $dpapi
    $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($de); $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    $igual = ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1) -ceq [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2))
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1); [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)
    Ok $igual "ida y vuelta (descifrado == original)"
    Ok (-not ($de.IsReadOnly -eq $false)) "el secreto descifrado queda de solo lectura"

    # Plantar el canario en un archivo UTF-8, otro UTF-16 y uno limpio.
    $arbol = Join-Path $tmp "arbol"; New-Item -ItemType Directory $arbol | Out-Null
    [IO.File]::WriteAllText((Join-Path $arbol "a-utf8.txt"), "x $canario y", [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $arbol "b-utf16.txt"), "x $canario y", [Text.Encoding]::Unicode)
    [IO.File]::WriteAllText((Join-Path $arbol "c-limpio.txt"), "nada que ver", [Text.Encoding]::UTF8)
    $h = @(Find-SecretLeak -Secret $ss -Path $arbol, $dirSec -Entorno -HistorialPS)
    $a = @($h | Where-Object { $_ -like "*a-utf8.txt" }).Count; $b = @($h | Where-Object { $_ -like "*b-utf16.txt" }).Count
    Ok ($a -eq 1 -and $b -eq 1) "encuentra la cadena en UTF-8 y UTF-16"
    Ok (@($h | Where-Object { $_ -like "*c-limpio.txt" -or $_ -like "*rabbitmq.dpapi" }).Count -eq 0) "no marca el archivo limpio ni el DPAPI"
    Ok (@($h | Where-Object { $_ -like "$canario*" -or $_ -like "*$canario*" }).Count -eq 0) "el informe no contiene el valor"
    [Environment]::SetEnvironmentVariable("T360_CANARIO_TEST", $canario, "Process")
    $h2 = @(Find-SecretLeak -Secret $ss -Entorno)
    [Environment]::SetEnvironmentVariable("T360_CANARIO_TEST", $null, "Process")
    Ok (@($h2 | Where-Object { $_ -like "ENTORNO(Process): variable T360_CANARIO_TEST" }).Count -eq 1) "encuentra la cadena en el entorno (solo nombre de variable)"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $h3 = @(Find-SecretLeak -Secret $ss -EventLog -Tareas)
    Ok ($h3.Count -eq 0) "Registro de Eventos y tareas programadas: sin hallazgos ($([int]$sw.Elapsed.TotalSeconds) s)"
    if ($h3.Count -gt 0) { $h3 | ForEach-Object { Write-Host "     ubicacion: $_" } }

    Write-Host "(b2) ACL restringida"
    $lock = Join-Path $tmp "bloqueada"
    Set-LockedAcl -Path $lock
    $acl = ((& icacls.exe $lock) -join " ").Replace($lock, "")   # sin la ruta (contiene "Users")
    Ok ($acl -match "SYSTEM" -and $acl -match "BUILTIN\\Administrators|Administradores") "solo SYSTEM y Administradores en la ACL"
    Ok ($acl -notmatch "Users|Usuarios|Everyone|Todos|AUTHENTICATED") "sin Users/Everyone/Authenticated Users"
    if (-not $esAdmin) {
        $negado = $false
        try { Get-ChildItem $lock -ErrorAction Stop | Out-Null } catch { $negado = $true }
        Ok $negado "un usuario no elevado NO puede leer la carpeta bloqueada"
    } else { Write-Host "  (elevado: se omite la comprobacion de acceso denegado)" }
    & icacls.exe $lock /reset /T /C | Out-Null   # propietario: puede restablecer para limpiar

    Write-Host "(c) estados, backoff, log rotado, vigilante"
    $hostOk = [pscustomobject]@{ Host = "h"; Port = 5672 }
    Ok ((Get-EstadoWorker -Motor $false -Tailscale $null -HostElegido $hostOk -Consumer "sano") -eq "MOTOR_CAIDO") "motor caido"
    Ok ((Get-EstadoWorker -Motor $true -Tailscale $false -HostElegido $hostOk -Consumer "sano") -eq "TAILSCALE_CAIDO") "tailscale caido (solo si se exige)"
    Ok ((Get-EstadoWorker -Motor $true -Tailscale $null -HostElegido $null -Consumer "sano") -eq "SIN_RUTA") "sin ruta a RabbitMQ"
    Ok ((Get-EstadoWorker -Motor $true -Tailscale $null -HostElegido $hostOk -Consumer "credenciales") -eq "CREDENCIALES") "ACCESS_REFUSED -> CREDENCIALES"
    Ok ((Get-AccionPorEstado -Estado "CREDENCIALES") -eq "ninguna") "CREDENCIALES no reinicia"
    Ok ((Get-AccionPorEstado -Estado "SIN_RUTA") -eq "ninguna") "SIN_RUTA no reinicia (espera la red)"
    Ok ((Get-AccionPorEstado -Estado "CONSUMER_CAIDO") -eq "reiniciar-worker") "CONSUMER_CAIDO reinicia"
    Ok ((Get-EstadoWorker -Motor $true -Tailscale $null -HostElegido $hostOk -Consumer "sano") -eq "OK") "OK"
    $r = (1..24 | Where-Object { Test-DebeReintentar -FallosConsecutivos $_ }) -join ","
    Ok ($r -eq "1,2,4,8,10,20") "backoff: actua en 1,2,4,8 y luego cada 10 ciclos ($r)"

    $lg = Join-Path $tmp "logs\x.log"
    1..60 | ForEach-Object { Write-RotatingLog -Path $lg -Message ("linea " + ("z" * 100)) -MaxBytes 2000 -Keep 3 }
    Ok ((Test-Path "$lg.1") -and (Test-Path "$lg.2") -and (Test-Path "$lg.3") -and -not (Test-Path "$lg.4")) "rotacion: conserva 3 archivos"

    $cfgDir = Join-Path $tmp "Techo360Worker"; New-Item -ItemType Directory $cfgDir | Out-Null
    '{"Hosts":"10.1.1.1,10.2.2.2","Tailscale":false}' | Set-Content (Join-Path $cfgDir "worker.config.json")
    $vig = Join-Path $PSScriptRoot "..\lib\vigilante.ps1"
    $cfgFile = Join-Path $cfgDir "worker.config.json"
    & $vig -Config $cfgFile -Dir $cfgDir -NoEventLog -Sondas @{ Motor = { $true }; Host = { [pscustomobject]@{ Host = "10.2.2.2"; Port = 5672 } }; Consumer = { "sano" } }
    $e1 = Get-Content (Join-Path $cfgDir "estado.json") -Raw | ConvertFrom-Json
    Ok ($e1.Estado -eq "OK" -and $e1.Host -eq "10.2.2.2:5672") "vigilante: estado OK y host elegido"
    & $vig -Config $cfgFile -Dir $cfgDir -NoEventLog -Sondas @{ Motor = { $true }; Host = { [pscustomobject]@{ Host = "10.2.2.2"; Port = 5672 } }; Consumer = { "credenciales" } }
    $e2 = Get-Content (Join-Path $cfgDir "estado.json") -Raw | ConvertFrom-Json
    $txt = Get-Content (Join-Path $cfgDir "logs\watchdog.log") -Raw
    Ok ($e2.Estado -eq "CREDENCIALES" -and $txt -match "CAMBIO DE ESTADO: OK -> CREDENCIALES" -and $txt -notmatch "ACCION reiniciar") "vigilante: CREDENCIALES, cambio registrado, sin reinicio"
    # El mutex es por HILO: la otra instancia debe tomarlo desde otro hilo (runspace aparte).
    $listo = New-Object System.Threading.ManualResetEvent($false); $suelta = New-Object System.Threading.ManualResetEvent($false)
    $ps = [powershell]::Create(); [void]$ps.AddScript({ param($l, $s)
        $m = New-Object System.Threading.Mutex($false, "Global\Techo360WorkerVigilante"); [void]$m.WaitOne(0); [void]$l.Set(); [void]$s.WaitOne(20000); $m.ReleaseMutex(); $m.Dispose() }).AddArgument($listo).AddArgument($suelta)
    $async = $ps.BeginInvoke(); [void]$listo.WaitOne(5000)
    & $vig -Config $cfgFile -Dir $cfgDir -NoEventLog -Sondas @{ Motor = { $true }; Host = { $null }; Consumer = { "sano" } }
    [void]$suelta.Set(); $ps.EndInvoke($async); $ps.Dispose()
    Ok ((Get-Content (Join-Path $cfgDir "logs\watchdog.log") -Raw) -match "Otra instancia del vigilante") "vigilante: segunda instancia se sale (mutex)"
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:fallos -gt 0) { Write-Host "`n$($script:fallos) prueba(s) FALLARON" -ForegroundColor Red; exit 1 }
Write-Host "`nTodas las pruebas pasaron." -ForegroundColor Green
