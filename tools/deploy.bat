@echo off
:: AIBattle deploy script — copies dev bots to Dota vscripts
:: Run from anywhere; no admin needed (xcopy only, no symlinks).

set DEV=%~dp0..\bots
set DOTA=C:\Program Files (x86)\Steam\steamapps\common\dota 2 beta\game\dota\scripts\vscripts\bots

echo === AIBattle Deploy ===
echo FROM: %DEV%
echo TO:   %DOTA%
echo.

:: --- Core bot files (FunLib) ---
copy /Y "%DEV%\FunLib\aibattle_style.lua"  "%DOTA%\FunLib\aibattle_style.lua"  && echo [OK] FunLib/aibattle_style.lua
copy /Y "%DEV%\FunLib\aibattle_heal.lua"  "%DOTA%\FunLib\aibattle_heal.lua"  && echo [OK] FunLib/aibattle_heal.lua
copy /Y "%DEV%\FunLib\jmz_func.lua"        "%DOTA%\FunLib\jmz_func.lua"        && echo [OK] FunLib/jmz_func.lua

:: --- Mode files ---
copy /Y "%DEV%\mode_laning_generic.lua"    "%DOTA%\mode_laning_generic.lua"    && echo [OK] mode_laning_generic.lua
copy /Y "%DEV%\mode_roam_generic.lua"      "%DOTA%\mode_roam_generic.lua"      && echo [OK] mode_roam_generic.lua

:: --- Customize (НЕ коммитить playstyle_radiant/dire) ---
copy /Y "%DEV%\Customize\general.lua"          "%DOTA%\Customize\general.lua"          && echo [OK] Customize/general.lua
copy /Y "%DEV%\Customize\playstyle_radiant.lua" "%DOTA%\Customize\playstyle_radiant.lua" && echo [OK] Customize/playstyle_radiant.lua
copy /Y "%DEV%\Customize\playstyle_dire.lua"    "%DOTA%\Customize\playstyle_dire.lua"    && echo [OK] Customize/playstyle_dire.lua

echo.
echo === Done. Restart lobby to pick up changes. ===
pause
