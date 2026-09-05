@echo off
rem Builds both helper tools from src\ into bin\.
setlocal
set "ROOT=%~dp0.."

set CSC=
for %%v in ("C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe") do if exist %%v set "CSC=%%~v"
if "%CSC%"=="" (
    echo ERROR: csc.exe not found. Is .NET Framework installed?
    pause
    exit /b 1
)

if not exist "%ROOT%\bin" mkdir "%ROOT%\bin"

"%CSC%" /nologo /target:exe /out:"%ROOT%\bin\SetWallpaper.exe" "%ROOT%\src\SetWallpaper.cs"
if errorlevel 1 goto failed
"%CSC%" /nologo /target:exe /out:"%ROOT%\bin\DisplayCtl.exe" "%ROOT%\src\DisplayCtl.cs"
if errorlevel 1 goto failed

echo Done. bin\SetWallpaper.exe and bin\DisplayCtl.exe built.
pause
exit /b 0

:failed
echo Compilation failed.
pause
exit /b 1
