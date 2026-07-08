# run.ps1 - build (incremental) and launch zig-diablo. The fast iteration loop.
#
# The Zig toolchain is pinned in a sibling folder (..\.zigtoolchain). The game
# static-links raylib into a single exe (no raylib.dll) installed to zig-out\bin,
# which is an AppLocker/SRP-allowed path (unlike %TEMP%). `zig build run` does an
# incremental compile then launches synchronously.
$ErrorActionPreference = "Stop"
$proj = $PSScriptRoot
$zig = (Get-ChildItem (Join-Path $proj "..\.zigtoolchain") -Filter "zig.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
if (-not $zig) { Write-Host "zig.exe not found under ..\.zigtoolchain"; exit 1 }

Get-Process -Name zig-diablo -ErrorAction SilentlyContinue | Stop-Process -Force
& $zig build run
