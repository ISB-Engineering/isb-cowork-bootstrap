@echo off
setlocal
cd /d "%~dp0"

set CSC=C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" (
  echo csc.exe not found at %CSC%
  exit /b 1
)

if exist isb-installer.exe del isb-installer.exe

"%CSC%" /nologo /target:winexe /out:isb-installer.exe /resource:installer.ps1 /reference:System.Windows.Forms.dll launcher.cs

if exist isb-installer.exe (
  echo OK: isb-installer.exe built
  dir isb-installer.exe
) else (
  echo FAIL
  exit /b 1
)
