@echo off
REM run-demo.cmd - double-click this (NOT the .ps1) to build + run the torch demo.
REM A point light orbits over boxes/sphere that cast real shadows. Close the window to quit.
setlocal
set "ZIG=%~dp0..\.zigtoolchain\zig-x86_64-windows-0.14.1\zig.exe"
echo Building torch demo...
"%ZIG%" build
if errorlevel 1 ( echo. & echo BUILD FAILED & pause & exit /b 1 )
echo.
echo Launching -- close the window to exit.
"%~dp0zig-out\bin\zig-diablo.exe" --demo
