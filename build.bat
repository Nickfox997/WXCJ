@echo off
chcp 65001 >nul
echo ============================================
echo  WeChatAIChatTweak - Windows 原生交叉编译
echo ============================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\win-build.ps1"
echo.
if errorlevel 1 (
  echo [失败] 上面是错误信息
) else (
  echo [成功] 产物：%~dp0libmarsbridge.dylib
)
echo.
pause
