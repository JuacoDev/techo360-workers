<#
.SYNOPSIS
    Arma tools-usb\ (inventario + spike + rootfs verificado + LEEME) para copiar a una USB.
#>
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$dest = Join-Path $root "tools-usb"
$rootfs = "alpine-minirootfs-3.20.3-x86_64.tar.gz"
$sha = "d4e6fd67dcf75e40c451560ac7265166c2b72a0f38ddc9aae756a7de3d1efa0c"
$src = Join-Path $PSScriptRoot "spike\$rootfs"
if (-not (Test-Path $src)) { throw "Falta $src (descargalo y vuelve a correr)." }
if ((Get-FileHash -Algorithm SHA256 $src).Hash.ToLower() -ne $sha) { throw "SHA-256 del rootfs no coincide." }
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
New-Item -ItemType Directory $dest | Out-Null
Copy-Item (Join-Path $PSScriptRoot "inventario-pc.ps1") $dest
Copy-Item (Join-Path $PSScriptRoot "spike\spike-arranque.ps1") $dest
Copy-Item (Join-Path $PSScriptRoot "spike\spike-boot.ps1") $dest
Copy-Item (Join-Path $PSScriptRoot "spike\LEEME-SPIKE.txt") $dest
Copy-Item $src $dest
Get-ChildItem $dest -File | Where-Object Name -ne "SHA256SUMS.txt" | ForEach-Object {
    "{0}  {1}" -f (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLower(), $_.Name
} | Set-Content (Join-Path $dest "SHA256SUMS.txt") -Encoding ASCII
Get-ChildItem $dest | Select-Object Name, Length | Format-Table -AutoSize
