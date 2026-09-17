@echo off
rem File Recovery Flow - thin double-click launcher for the recovery workflow.
rem This file starts one script and nothing else: it copies, moves, deletes,
rem formats, and repairs nothing. All workflow logic and every safety check live
rem in RecoveryAutomation.ps1.
rem The entry point starts Windows PowerShell 5.1 and self-elevates through UAC
rem when required; the elevated child is waited on and its exit code is returned.
rem Usage: Start-Recovery.bat <entry point arguments> [-NoPause]
rem Closing prompt: keep the console open so a double-click user can read the
rem result. Set RECOVERY_NO_PAUSE, or pass -NoPause, to suppress it. Automated
rem callers must suppress it so a redirected console cannot wait for a keypress.
setlocal EnableExtensions
set "RECOVERY_LAUNCHER=%~dp0"
set "RECOVERY_ENTRYPOINT=%~dp0RecoveryAutomation.ps1"
set "RECOVERY_PS_ARGS=%*"
:RECOVERY_SCAN_ARGS
if "%~1"=="" goto RECOVERY_ARGS_DONE
if /i "%~1"=="-NoPause" set "RECOVERY_NO_PAUSE=1"
shift
goto RECOVERY_SCAN_ARGS
:RECOVERY_ARGS_DONE
cd /d "%RECOVERY_LAUNCHER%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%RECOVERY_ENTRYPOINT%" %RECOVERY_PS_ARGS%
set "RECOVERY_EXIT_CODE=%ERRORLEVEL%"
if not defined RECOVERY_NO_PAUSE pause
exit /b %RECOVERY_EXIT_CODE%
