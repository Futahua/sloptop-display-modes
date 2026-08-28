@echo off
rem Thin wrapper. All logic lives in apply-mode.ps1, which resolves monitors by
rem role at run time instead of by hardcoded id - those are not stable on this
rem machine and a stale id makes every command fail silently.
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\Programs\multimonitortool-x64\apply-mode.ps1" -Mode ipad