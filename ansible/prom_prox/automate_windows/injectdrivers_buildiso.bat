@echo off
SETLOCAL

:: ========================================================================
:: Script to Inject VirtIO Drivers and Build a Bootable Windows 11 ISO
::                           -- ALL-IN-ONE --
:: ========================================================================

:: --- Configuration ---
SET "WORK_DIR=C:\ISO_BUILD"
SET "DRIVER_DIR=C:\DRIVERS"
SET "MOUNT_DIR=C:\MOUNT"
SET "FINAL_ISO_NAME=C:\Windows11-Proxmox-Ready.iso"

:: WIM File Paths
SET "BOOT_WIM_PATH=%WORK_DIR%\sources\boot.wim"
SET "INSTALL_WIM_PATH=%WORK_DIR%\sources\install.wim"

:: WIM Image Indexes (Customize if needed)
SET "BOOT_WIM_RE_INDEX=1"
SET "BOOT_WIM_SETUP_INDEX=2"
SET "INSTALL_WIM_INDEX=6"
:: Note: Index 6 is typically Windows 11 Pro. Use "dism /get-imageinfo" to verify.

:: --- DO NOT EDIT BELOW THIS LINE ---

:: 1. Initial Checks
ECHO.
ECHO ========================================================================
ECHO  Phase 0: Pre-flight Checks
ECHO ========================================================================
ECHO.

:: Check for Administrator privileges
net session >nul 2>&1
if %errorLevel% NEQ 0 (
    ECHO ERROR: This script requires administrative privileges.
    ECHO Please right-click and "Run as administrator" from within the
    ECHO "Deployment and Imaging Tools Environment".
    pause
    EXIT /B 1
)
ECHO [+] Admin privileges: OK

:: Verify that the source files have been copied
IF NOT EXIST "%INSTALL_WIM_PATH%" (ECHO ERROR: C:\ISO_BUILD\sources\install.wim not found! Please run the prep script and copy files first.& pause & EXIT /B 1)
IF NOT EXIST "%DRIVER_DIR%\viostor" (ECHO ERROR: C:\DRIVERS\viostor not found! Please copy drivers first.& pause & EXIT /B 1)
ECHO [+] Source files and drivers found: OK
ECHO.
ECHO  IMPORTANT: Have you temporarily disabled your Antivirus?
ECHO  DISM can hang during the 'commit' phase if antivirus is active.
ECHO.
pause

:: Cleanup any previous failed mount points
ECHO.
ECHO --- Cleaning up any previous failed mounts... ---
dism /Cleanup-Mountpoints >nul 2>&1
dism /Unmount-Image /MountDir:"%MOUNT_DIR%" /Discard >nul 2>&1
ECHO Done.
ECHO.

:: 2. Driver Injection Phase
ECHO ========================================================================
ECHO  Phase 1: Injecting Drivers into WIM files
ECHO ========================================================================
ECHO.

ECHO --- Processing boot.wim (Index %BOOT_WIM_RE_INDEX% - Windows RE) ---
dism /Mount-Image /ImageFile:"%BOOT_WIM_PATH%" /Index:%BOOT_WIM_RE_INDEX% /MountDir:"%MOUNT_DIR%" || GOTO Error
dism /Image:"%MOUNT_DIR%" /Add-Driver /Driver:"%DRIVER_DIR%" /Recurse || GOTO Error
dism /Unmount-Image /MountDir:"%MOUNT_DIR%" /Commit || GOTO Error
ECHO SUCCESS: boot.wim [RE] has been updated.
ECHO.

ECHO --- Processing boot.wim (Index %BOOT_WIM_SETUP_INDEX% - Windows Setup) ---
dism /Mount-Image /ImageFile:"%BOOT_WIM_PATH%" /Index:%BOOT_WIM_SETUP_INDEX% /MountDir:"%MOUNT_DIR%" || GOTO Error
dism /Image:"%MOUNT_DIR%" /Add-Driver /Driver:"%DRIVER_DIR%" /Recurse || GOTO Error
dism /Unmount-Image /MountDir:"%MOUNT_DIR%" /Commit || GOTO Error
ECHO SUCCESS: boot.wim [Setup] has been updated.
ECHO.

ECHO --- Processing install.wim (Index %INSTALL_WIM_INDEX% - Final OS) ---
ECHO Mounting install.wim... (This may take a few minutes)
dism /Mount-Image /ImageFile:"%INSTALL_WIM_PATH%" /Index:%INSTALL_WIM_INDEX% /MountDir:"%MOUNT_DIR%" || GOTO Error
ECHO Injecting drivers...
dism /Image:"%MOUNT_DIR%" /Add-Driver /Driver:"%DRIVER_DIR%" /Recurse || GOTO Error
ECHO Committing changes to install.wim... (This WILL take a long time!)
dism /Unmount-Image /MountDir:"%MOUNT_DIR%" /Commit || GOTO Error
ECHO SUCCESS: install.wim has been updated.
ECHO.

:: 3. ISO Creation Phase
ECHO ========================================================================
ECHO  Phase 2: Building Final Bootable ISO
ECHO ========================================================================
ECHO.
oscdimg -m -o -u2 -bootdata:2#p0,e,b"%WORK_DIR%\boot\etfsboot.com"#pEF,e,b"%WORK_DIR%\efi\microsoft\boot\efisys.bin" "%WORK_DIR%" "%FINAL_ISO_NAME%"
IF %ERRORLEVEL% NEQ 0 (ECHO ERROR: oscdimg failed to create the ISO.& GOTO End)

ECHO.
ECHO ========================================================================
ECHO  ALL DONE!
ECHO ========================================================================
ECHO.
ECHO Your custom ISO has been successfully created at:
ECHO %FINAL_ISO_NAME%
ECHO.
ECHO !!! REMEMBER TO RE-ENABLE YOUR ANTIVIRUS SOFTWARE NOW !!!
ECHO.
GOTO End

:Error
ECHO.
ECHO ########################################################################
ECHO #   AN ERROR OCCURRED!
ECHO ########################################################################
ECHO.
ECHO Script failed. Discarding any changes to mounted images...
dism /Unmount-Image /MountDir:"%MOUNT_DIR%" /Discard >nul 2>&1

:End
pause
