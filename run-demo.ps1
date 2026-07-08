# run-demo.ps1 - build + launch the standalone point-light shadow demo (live).
# The light orbits; boxes/sphere cast real shadows. Esc/close to quit.
$ErrorActionPreference = "Stop"
$proj = $PSScriptRoot
$zig = Join-Path $proj "..\.zigtoolchain\zig-x86_64-windows-0.14.1\zig.exe"
Get-Process -Name zig-diablo -ErrorAction SilentlyContinue | Stop-Process -Force
& $zig build
if ($LASTEXITCODE -ne 0) { Write-Host "build failed"; exit 1 }
& (Join-Path $proj "zig-out\bin\zig-diablo.exe") --demo
