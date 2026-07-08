@echo off
REM run-demo2.cmd - double-click to build + run the BASICS demo:
REM a point light that moves with you (WASD), casting shadows from blocks on a plane.
setlocal
set "ZIG=%~dp0..\.zigtoolchain\zig-x86_64-windows-0.14.1\zig.exe"
echo Building...
"%ZIG%" build
if errorlevel 1 ( echo. & echo BUILD FAILED & pause & exit /b 1 )
echo Launching -- WASD to move, close the window to exit.
"%~dp0zig-out\bin\zig-diablo.exe" --demo2
