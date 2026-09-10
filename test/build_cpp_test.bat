@echo off
setlocal
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "GB_VS=%%i"
if not defined GB_VS exit /b 1
call "%GB_VS%\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b 1
if not exist build mkdir build
cl /nologo /W4 /EHsc /permissive- /std:c++20 /DUNICODE /D_UNICODE /DNOMINMAX /LD /FAs /Fa:build\glassbar_test.cod /Fo:build\ /Fe:build\glassbar-cpp-test.dll glassbar_test.cpp /link user32.lib runtimeobject.lib windowsapp.lib
