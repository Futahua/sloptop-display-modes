@echo off
cd /d "D:\Programs\multimonitortool-x64"
echo Compiling SetWallpaper.exe...

set CSC=
for /f "delims=" %%i in ('dir /b /s /a-d "C:\Windows\Microsoft.NET\Framework64\csc.exe" 2^>nul') do set CSC=%%i

if "%CSC%"=="" (
    echo ERROR: csc.exe not found. Is .NET Framework installed?
    pause
    exit /b 1
)

"%CSC%" /target:exe /out:SetWallpaper.exe SetWallpaper.cs
if %errorlevel%==0 (
    echo Done. SetWallpaper.exe created.
) else (
    echo Compilation failed.
)
pause
