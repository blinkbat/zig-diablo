@echo off
REM build-release.cmd - optimized build for playing/shipping. Type "build-release".
REM ReleaseFast: full optimization, safety checks off, smallest/fastest exe.
REM (Use build.cmd / run.ps1 for day-to-day iteration; Debug compiles far faster.)
setlocal
set "ZIG=%~dp0..\.zigtoolchain\zig-x86_64-windows-0.14.1\zig.exe"
"%ZIG%" build -Doptimize=ReleaseFast
if errorlevel 1 ( echo BUILD FAILED & exit /b 1 )
echo BUILD OK (ReleaseFast): zig-out\bin\zig-diablo.exe
