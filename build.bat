@echo off
setlocal
where nasm >nul 2>nul || (echo NASM was not found in PATH.& exit /b 1)
where gcc >nul 2>nul || (echo GCC was not found in PATH.& exit /b 1)
if not exist build mkdir build
nasm -f win64 src\glassbar_direct.asm -o build\glassbar_direct.obj || exit /b 1
gcc -shared -nostdlib -Wl,--entry,DllMain -o build\glassbar_direct.dll build\glassbar_direct.obj -luser32 -lkernel32 -lruntimeobject || exit /b 1
nasm -f win64 src\glassbar_runner.asm -o build\glassbar_runner.obj || exit /b 1
gcc -nostdlib -mwindows -Wl,-e,start -o build\glassbar.exe build\glassbar_runner.obj -luser32 -lkernel32 || exit /b 1
echo Built build\glassbar.exe and build\glassbar_direct.dll
