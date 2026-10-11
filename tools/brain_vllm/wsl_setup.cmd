@echo off
REM BRAIN_VLLM_PHASE1 - Windows driver for WSL distro (re)creation + provisioning.
REM Idempotent: if the distro exists it is only re-provisioned. Goes to D:\WSL\Ubuntu-24.04.
setlocal
set DISTRO=Ubuntu-24.04
set LOC=D:\WSL\Ubuntu-24.04
set SCRIPT=%~dp0wsl_setup.sh

wsl.exe -l -q | findstr /x /c:"%DISTRO%" >nul 2>&1
if errorlevel 1 (
  echo [wsl] installing %DISTRO% at %LOC% ...
  wsl.exe --install %DISTRO% --location "%LOC%" --name %DISTRO% --no-launch --web-download --version 2 || exit /b 1
) else (
  echo [wsl] distro %DISTRO% already registered
)

echo [wsl] copying setup script...
wsl.exe -d %DISTRO% -u root -- mkdir -p /opt/brain_vllm
wsl.exe -d %DISTRO% -u root -- bash -lc "cat > /opt/brain_vllm/wsl_setup.sh" < "%SCRIPT%" || exit /b 1

if not "%~1"=="" (
  echo [wsl] provisioning with vllm spec %~1 ...
  wsl.exe -d %DISTRO% -u root -- bash /opt/brain_vllm/wsl_setup.sh %~1
) else (
  echo [wsl] provisioning (default vllm spec) ...
  wsl.exe -d %DISTRO% -u root -- bash /opt/brain_vllm/wsl_setup.sh
)
endlocal
