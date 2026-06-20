@echo off
setlocal EnableExtensions

:: AIBattle deploy script.
:: Profiles:
::   code       default; engine + bot code only
::   playstyle  canonical presets + live bindings
::   all        code + playstyle, never general.lua
::   general    explicit lobby/general sync
::   check      print the full copy plan without writing

set "DEV=%~dp0..\bots"
set "DOTA=C:\Program Files (x86)\Steam\steamapps\common\dota 2 beta\game\dota\scripts\vscripts\bots"
set "PROFILE=%~1"
if "%PROFILE%"=="" set "PROFILE=code"

set "DO_CODE=0"
set "DO_PLAYSTYLE=0"
set "DO_GENERAL=0"
set "DRY_RUN=0"

if /I "%PROFILE%"=="code" set "DO_CODE=1"
if /I "%PROFILE%"=="playstyle" set "DO_PLAYSTYLE=1"
if /I "%PROFILE%"=="all" (
	set "DO_CODE=1"
	set "DO_PLAYSTYLE=1"
)
if /I "%PROFILE%"=="general" set "DO_GENERAL=1"
if /I "%PROFILE%"=="check" (
	set "DO_CODE=1"
	set "DO_PLAYSTYLE=1"
	set "DO_GENERAL=1"
	set "DRY_RUN=1"
)

if "%DO_CODE%%DO_PLAYSTYLE%%DO_GENERAL%%DRY_RUN%"=="0000" (
	echo Usage: tools\deploy.bat [code^|playstyle^|all^|general^|check]
	echo.
	echo code is the default. general.lua is explicit only.
	exit /b 2
)

echo === AIBattle Deploy ===
echo PROFILE: %PROFILE%
echo FROM:    %DEV%
echo TO:      %DOTA%
if "%DRY_RUN%"=="1" echo MODE:    dry run
echo.

if "%DO_CODE%"=="1" (
	echo -- code --
	call :copyfile "FunLib\aibattle_engine.lua" || exit /b 1
	call :copyfile "FunLib\aibattle_style.lua" || exit /b 1
	call :copyfile "FunLib\aibattle_survive.lua" || exit /b 1
	call :copyfile "FunLib\aibattle_utils.lua" || exit /b 1
	call :copyfile "FunLib\jmz_func.lua" || exit /b 1
	call :copyfile "mode_laning_generic.lua" || exit /b 1
	call :copyfile "mode_roam_generic.lua" || exit /b 1
	call :copyfile "FretBots\SettingsDefault.lua" || exit /b 1
	echo.
)

if "%DO_PLAYSTYLE%"=="1" (
	echo -- playstyle --
	call :copyfile "Customize\canonical_pusher.lua" || exit /b 1
	call :copyfile "Customize\canonical_ganker.lua" || exit /b 1
	call :copyfile "Customize\playstyle_radiant.lua" || exit /b 1
	call :copyfile "Customize\playstyle_dire.lua" || exit /b 1
	echo.
)

if "%DO_GENERAL%"=="1" (
	echo -- general --
	call :copyfile "Customize\general.lua" || exit /b 1
	echo.
)

echo === Done. Restart lobby to pick up changes. ===
exit /b 0

:copyfile
if "%DRY_RUN%"=="1" (
	echo [PLAN] %~1
	exit /b 0
)
copy /Y "%DEV%\%~1" "%DOTA%\%~1" >nul
if errorlevel 1 (
	echo [ERR] %~1
	exit /b 1
)
echo [OK] %~1
exit /b 0
