@echo off
rem Thin wrapper. All logic lives in scripts\apply-mode.ps1, which resolves
rem monitors by role at run time - hardcoded ids are not stable on this machine
rem and a stale one makes every command fail silently.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\apply-mode.ps1" -Mode ipadmon