@echo off
ECHO.
ECHO =============================================================
ECHO      Windows ISO Preparation - Folder Setup
ECHO =============================================================
ECHO.
ECHO This script will create the necessary folders for the build process.
ECHO.

:: Create the main project directories
mkdir C:\ISO_BUILD >nul 2>&1
mkdir C:\DRIVERS >nul 2>&1
mkdir C:\MOUNT >nul 2>&1

ECHO Folders have been created:
ECHO   - C:\ISO_BUILD
ECHO   - C:\DRIVERS
ECHO   - C:\MOUNT
ECHO.
ECHO -------------------------------------------------------------
ECHO   NEXT STEPS - MANUAL ACTION REQUIRED:
ECHO -------------------------------------------------------------
ECHO.
ECHO 1. Mount the Windows 11 ISO and copy its ENTIRE contents
ECHO    into the "C:\ISO_BUILD" folder.
ECHO.
ECHO 2. Mount the VirtIO Drivers ISO.
ECHO    - Copy the contents of "\viostor\w11\amd64" into "C:\DRIVERS\viostor"
ECHO    - Copy the contents of "\NetKVM\w11\amd64"  into "C:\DRIVERS\NetKVM"
ECHO.
ECHO 3. (Optional) Place your "autounattend.xml" file into "C:\ISO_BUILD".
ECHO.
ECHO After you have copied the files, you can run the main script.
ECHO.
pause
