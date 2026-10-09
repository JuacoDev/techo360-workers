<#
.SYNOPSIS
    Inventario de SOLO LECTURA de un PC (para decidir si puede ser worker de Techo 360).

.DESCRIPTION
    No instala, no cambia ni escribe nada en el sistema (excepto el archivo de salida si se pide).
    No imprime secretos: AutoAdminLogon solo informa si hay o no un password guardado, nunca su valor.
    Algunas lecturas necesitan PowerShell como Administrador (marcadas "requiere admin"); sin
    admin se informa "no disponible" en vez de fallar.

.PARAMETER Salida
    Ruta opcional de un .txt donde ademas guardar el informe.

.PARAMETER ProbarRed
    Host:puerto a probar con TCP (por defecto 10.154.12.191:5672 y 100.116.197.118:5672).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\inventario-pc.ps1 -Salida .\inventario.txt
#>
param(
    [string]$Salida,
    [string[]]$ProbarRed = @("10.154.12.191:5672", "100.116.197.118:5672")
)
$ErrorActionPreference = "Continue"
$lineas = New-Object System.Collections.Generic.List[string]
function Out-L([string]$t) { Write-Host $t; $lineas.Add($t) }
function Sec([string]$t) { Out-L ""; Out-L "== $t ==" }
function Kv([string]$k, $v) { Out-L ("{0,-40} {1}" -f $k, $v) }
function Try-Get([scriptblock]$b, $fallback = "no disponible") {
    try { $r = & $b; if ($null -eq $r -or "$r" -eq "") { $fallback } else { $r } } catch { $fallback }
}

$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Out-L "Inventario Techo 360 worker - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - equipo $env:COMPUTERNAME"
Kv "Ejecutado como administrador" $esAdmin

Sec "Sistema operativo"
$os = Get-CimInstance Win32_OperatingSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Kv "Windows" "$($os.Caption) (build $($os.BuildNumber).$($cv.UBR))"
Kv "Edicion" $cv.EditionID
Kv "Arquitectura" $os.OSArchitecture
Kv "Ultimo arranque" $os.LastBootUpTime
Kv "Politica de ejecucion de scripts" (Try-Get { (Get-ExecutionPolicy -List | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }) -join "; " })

Sec "Hardware"
$cs = Get-CimInstance Win32_ComputerSystem
$cpu = @(Get-CimInstance Win32_Processor)
Kv "CPU" $cpu[0].Name.Trim()
Kv "Nucleos fisicos / logicos" "$(($cpu | Measure-Object NumberOfCores -Sum).Sum) / $(($cpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum)"
Kv "RAM total (GiB)" ([math]::Round($cs.TotalPhysicalMemory / 1GB, 1))
Kv "RAM libre ahora (GiB)" ([math]::Round($os.FreePhysicalMemory / 1MB, 1))
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    Kv "Disco $($_.DeviceID) libre/total (GiB)" "$([math]::Round($_.FreeSpace/1GB,1)) / $([math]::Round($_.Size/1GB,1)) ($($_.FileSystem))"
}
Kv "GPU" (Try-Get { (Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }) -join "; " })

Sec "Virtualizacion"
Kv "Virtualizacion habilitada en firmware" (Try-Get { $cpu[0].VirtualizationFirmwareEnabled })
Kv "Hipervisor activo (Windows corre sobre el)" $cs.HypervisorPresent
Kv "Secure Boot" (Try-Get { Confirm-SecureBootUEFI })
if ($esAdmin) {
    foreach ($f in "Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform", "Microsoft-Hyper-V-All", "HypervisorPlatform") {
        Kv "Caracteristica $f" (Try-Get { (Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop).State })
    }
} else {
    Kv "Caracteristicas WSL/VMP/Hyper-V" "no disponible (requiere admin)"
}
$wslExe = Get-Command wsl.exe -ErrorAction SilentlyContinue
Kv "wsl.exe presente" ([bool]$wslExe)
if ($wslExe) {
    $w = Try-Get { (& wsl.exe --status 2>&1 | Out-String) -replace "`0", "" }
    Kv "wsl --status" (($w -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 4) -join " | ")
    $d = Try-Get { (& wsl.exe -l -v 2>&1 | Out-String) -replace "`0", "" }
    Kv "wsl -l -v" (($d -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 6) -join " | ")
}

Sec "Control de aplicaciones (puede bloquear .exe sin firma de confianza)"
Kv "Smart App Control (0=off,1=on,2=eval)" (Try-Get { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction Stop).VerifiedAndReputablePolicyState })
Kv "Politicas WDAC activas (.cip)" (Try-Get { @(Get-ChildItem 'C:\Windows\System32\CodeIntegrity\CiPolicies\Active' -Filter *.cip -ErrorAction Stop).Count } "0 o no legible")
Kv "SiPolicy.p7b (politica heredada)" (Test-Path 'C:\Windows\System32\CodeIntegrity\SiPolicy.p7b')
Kv "AppLocker (colecciones de reglas)" (Try-Get { @((Get-AppLockerPolicy -Effective -ErrorAction Stop).RuleCollections).Count } "no disponible")
Kv "Servicio AppIDSvc" (Try-Get { (Get-Service AppIDSvc -ErrorAction Stop).Status })

Sec "Software presente"
Kv "Docker Desktop instalado" (Test-Path 'C:\Program Files\Docker\Docker\Docker Desktop.exe')
Kv "docker.exe en PATH" ([bool](Get-Command docker -ErrorAction SilentlyContinue))
Kv "Servicio Docker (com.docker.service)" (Try-Get { (Get-Service com.docker.service -ErrorAction Stop).Status })
Kv "Tailscale instalado" (Test-Path 'C:\Program Files\Tailscale\tailscale.exe')
Kv "Servicio Tailscale" (Try-Get { (Get-Service Tailscale -ErrorAction Stop).Status })
Kv "Ollama nativo (ollama.exe)" ([bool](Get-Command ollama -ErrorAction SilentlyContinue))
Kv "Python en PATH" (Try-Get { (& python --version 2>&1 | Out-String).Trim() } "no")
Kv "winget disponible" ([bool](Get-Command winget -ErrorAction SilentlyContinue))

Sec "Inicio de sesion automatico (NO se imprime ningun password)"
$p = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
Kv "AutoAdminLogon" (Try-Get { $p.AutoAdminLogon } "no definido")
Kv "DefaultUserName definido" ([bool]$p.DefaultUserName)
Kv "DefaultPassword guardado en registro" ([bool]$p.DefaultPassword)
Kv "Congelador de disco (Deep Freeze, etc.)" (Try-Get { ((Get-Service | Where-Object { $_.Name -match 'DFServ|Faronics|DeepFreeze|SteadyState' } | ForEach-Object { $_.Name }) -join ",") } "ninguno detectado")

Sec "Energia"
Kv "Plan activo" (Try-Get { (powercfg /getactivescheme) -join " " })
foreach ($q in @(@("STANDBYIDLE", "Suspender en CA, segundos (0=nunca)"), @("HIBERNATEIDLE", "Hibernar en CA, segundos (0=nunca)"))) {
    $o = Try-Get { powercfg /query SCHEME_CURRENT SUB_SLEEP $q[0] 2>&1 | Out-String } ""
    # La linea de AC es la penultima con un valor 0x...; sirve en cualquier idioma.
    $hex = @([regex]::Matches($o, '0x[0-9a-fA-F]{8}') | ForEach-Object { $_.Value })
    $val = if ($hex.Count -ge 2) { [Convert]::ToInt32($hex[$hex.Count - 2], 16) } else { "no legible" }
    Kv $q[1] $val
}

Sec "Apagados / reinicios programados"
$tareas = @(Try-Get {
    Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.State -ne 'Disabled' } | Where-Object {
        (($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join " ") -match 'shutdown|Stop-Computer|Restart-Computer|poweroff'
    } | ForEach-Object { "$($_.TaskPath)$($_.TaskName) [$($_.State)]" }
} @())
if ($tareas.Count -gt 0 -and $tareas[0] -ne "") { foreach ($t in $tareas) { Kv "Tarea con apagado/reinicio" $t } } else { Kv "Tareas que apagan/reinician" "ninguna detectada" }
Out-L "Revisar tambien en BIOS: encendido automatico (Wake on LAN / RTC alarm / 'AC Power Recovery')."

Sec "Alcance de red (TCP, 4 s de espera)"
foreach ($hp in $ProbarRed) {
    $h, $pt = $hp -split ":"
    $r = try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect($h, [int]$pt, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(4000) -and $c.Connected
        $c.Close()
        if ($ok) { "ALCANZABLE" } else { "SIN RESPUESTA (timeout)" }
    } catch { "ERROR: $($_.Exception.Message)" }
    Kv "TCP $hp" $r
}
Kv "Proxy del sistema (WinHTTP)" (Try-Get { (netsh winhttp show proxy | Where-Object { $_.Trim() } | Select-Object -Skip 1) -join " " })

Out-L ""
Out-L "Fin del inventario (solo lectura)."
if ($Salida) { $lineas | Set-Content -Path $Salida -Encoding UTF8; Write-Host "Guardado en $Salida" }
