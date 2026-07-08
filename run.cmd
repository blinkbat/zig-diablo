@echo off
REM run.cmd - build (incremental) and launch zig-diablo. Type "run" in cmd.exe.
REM Zig static-links raylib (no raylib.dll); the exe installs to zig-out\bin, an
REM AppLocker-allowed path. "zig build run" compiles then launches synchronously.
setlocal
set "ZIG=%~dp0..\.zigtoolchain\zig-x86_64-windows-0.14.1\zig.exe"
taskkill /IM zig-diablo.exe /F >nul 2>&1
"%ZIG%" build run
