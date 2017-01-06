@echo off

C:\D\dmd2\src\druntime\make.exe
cd ..\phobos
C:\D\dmd2\src\phobos\make.exe

copy C:\D\dmd2\src\druntime\lib\gcstub.obj C:\D\dmd2\windows\lib\gcstub.obj
copy C:\D\dmd2\src\phobos\phobos.lib C:\D\dmd2\windows\lib\phobos.lib

pause
