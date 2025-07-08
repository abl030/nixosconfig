@echo off
:: #####################################################################
:: ##                                                                 ##
:: ##      This script enables automatic login for a local user.      ##
:: ##      IT MUST BE RUN AS AN ADMINISTRATOR.                        ##
:: ##                                                                 ##
:: ##      WARNING: Stores your password in plain text in the         ##
:: ##      Windows Registry. Use only on a secure, single-user VM.    ##
:: ##                                                                 ##
:: #####################################################################

:: Self-elevate to administrator if not already running as admin
net session >nul 2>&1
if %errorLevel% NEQ 0 (
    echo Requesting administrative privileges...
    powershell.exe -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo === Enable Windows Auto-Login ===
echo.

:: Get user credentials
set /p "username=Enter the username to auto-login: "
if not defined username (
    echo Username cannot be empty.
    goto :end
)

set /p "password=Enter the password for %username%: "
if not defined password (
    echo Password cannot be empty for auto-login.
    goto :end
)

echo.
echo Configuring registry for user: %username%
echo On computer: %COMPUTERNAME%
echo.

:: Set the required registry keys
set "RegKey=HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

reg add "%RegKey%" /v DefaultUserName /t REG_SZ /d "%username%" /f >nul
reg add "%RegKey%" /v DefaultPassword /t REG_SZ /d "%password%" /f >nul
reg add "%RegKey%" /v DefaultDomainName /t REG_SZ /d "%COMPUTERNAME%" /f >nul
reg add "%RegKey%" /v AutoAdminLogon /t REG_SZ /d "1" /f >nul

echo.
echo --- SUCCESS ---
echo Auto-login has been enabled for '%username%'.
echo Please reboot the VM to apply the changes.
echo.

:end
pause
