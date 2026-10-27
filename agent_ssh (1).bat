@echo off
chcp 65001 >nul
title Agent SSH

rem === Права администратора ===
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Запрашиваю права администратора...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

set "KEY=%USERPROFILE%\agent_key"
set "AKF=%ProgramData%\ssh\agent_authorized_keys"

:menu
cls
echo ==========================================
echo   SSH-доступ для агента (Windows)
echo ==========================================
echo   1 - Установка (один раз)
echo   2 - Запуск (sshd + туннель ngrok)
echo   3 - Остановка
echo   4 - Показать приватный ключ
echo   5 - Полное удаление
echo   6 - Ввести токен ngrok
echo   0 - Выход
echo.
choice /c 1234560 /n /m "Выбор: "
if errorlevel 7 exit /b
if errorlevel 6 goto do_token
if errorlevel 5 goto do_remove
if errorlevel 4 goto do_showkey
if errorlevel 3 goto do_stop
if errorlevel 2 goto do_run
if errorlevel 1 goto do_install
goto menu

rem ==========================================
:do_install
cls
echo [1/6] Установка OpenSSH Server...
powershell -NoProfile -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"
sc config sshd start= demand >nul
net start sshd >nul 2>&1
net stop sshd >nul 2>&1
sc query sshd >nul 2>&1
if errorlevel 1 goto err_ssh

echo [2/6] Пользователь agent (обычные права, пароль случайный и не нужен)...
powershell -NoProfile -Command "if (-not (Get-LocalUser -Name agent -ErrorAction SilentlyContinue)) { $c='abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'; $p=-join (1..24 | ForEach-Object { $c[(Get-Random -Maximum $c.Length)] }); New-LocalUser -Name agent -Password (ConvertTo-SecureString $p -AsPlainText -Force) -PasswordNeverExpires -Description 'SSH agent' | Out-Null; Add-LocalGroupMember -Group (Get-LocalGroup -SID S-1-5-32-545) -Member agent }"

echo [3/6] Доступ только к папке проекта.
set "PROJ="
set /p PROJ=Путь к папке проекта (например C:\proj), Enter - пропустить: 
if "%PROJ%"=="" goto skip_acl
if not exist "%PROJ%" mkdir "%PROJ%"
icacls "%PROJ%" /grant agent:(OI)(CI)M
:skip_acl

echo [4/6] Генерация ключа...
if exist "%KEY%" del /f /q "%KEY%"
if exist "%KEY%.pub" del /f /q "%KEY%.pub"
ssh-keygen -t ed25519 -N "" -f "%KEY%" -C agent >nul
copy /y "%KEY%.pub" "%AKF%" >nul
icacls "%AKF%" /inheritance:r /grant "*S-1-5-18:F" "*S-1-5-32-544:F" >nul

echo [5/6] Настройка sshd_config (только localhost, только ключ, только agent)...
powershell -NoProfile -Command "$f=Join-Path $env:ProgramData 'ssh\sshd_config'; $n=[Environment]::NewLine; $t=Get-Content $f -Raw; $t=[regex]::Replace($t,'(?s)# AGENT-BEGIN.*?# AGENT-END\s*',''); $b=@('# AGENT-BEGIN','ListenAddress 127.0.0.1','PasswordAuthentication no','AllowUsers agent','StrictModes no','AuthorizedKeysFile __PROGRAMDATA__/ssh/agent_authorized_keys','# AGENT-END') -join $n; Set-Content -Path $f -Value ($b+$n+$t) -Encoding ascii"

echo [6/6] ngrok...
where ngrok >nul 2>&1
if errorlevel 1 (
  echo ngrok не найден, ставлю через winget...
  winget install -e --id Ngrok.Ngrok --accept-source-agreements --accept-package-agreements
  echo Если ngrok не виден сразу, перезапустите bat, установка SSH уже сделана.
)
call :set_token

echo.
echo Готово. Теперь выберите пункт 2 для запуска.
echo Приватный ключ: %KEY%  (пункт 4 покажет его текст)
pause
goto menu

:err_ssh
echo.
echo Не удалось установить OpenSSH Server. Проверьте интернет и запустите снова.
pause
goto menu

rem ==========================================
:do_token
cls
call :set_token
pause
goto menu

rem Подпрограмма: ввод токена. Любая неудача не прерывает работу.
:set_token
set "TOKEN="
set /p TOKEN=Authtoken ngrok (dashboard.ngrok.com), Enter - пропустить: 
if "%TOKEN%"=="" (
  echo Токен не введён, пропускаю и продолжаю работу.
  exit /b 0
)
where ngrok >nul 2>&1
if errorlevel 1 (
  echo ngrok пока не найден, токен не добавлен. Продолжаю.
  exit /b 0
)
ngrok config add-authtoken %TOKEN%
if errorlevel 1 echo Не удалось добавить токен, продолжаю без него.
exit /b 0

rem ==========================================
:do_run
cls
echo Перезапуск sshd...
net stop sshd >nul 2>&1
net start sshd
sc query sshd | find "RUNNING" >nul
if errorlevel 1 goto err_run

where ngrok >nul 2>&1
if errorlevel 1 goto no_ngrok
taskkill /f /im ngrok.exe >nul 2>&1
echo Запуск туннеля ngrok (окно ngrok не закроется само, даже при ошибке)...
start "ngrok tunnel" cmd /k "ngrok tcp 22"
echo Жду адрес туннеля...
timeout /t 6 /nobreak >nul
echo.
echo Адрес туннеля (host:port):
powershell -NoProfile -Command "try { (Invoke-RestMethod http://127.0.0.1:4040/api/tunnels).tunnels | ForEach-Object { $_.public_url } } catch { 'Адрес не получен, смотрите окно ngrok' }"
echo.
echo Если в окне ngrok ошибка про authtoken, выберите пункт 6 и введите токен, затем снова пункт 2.
goto run_end

:no_ngrok
echo.
echo ngrok не найден: sshd запущен, но туннель не создан.
echo Установите ngrok (пункт 1 или winget install Ngrok.Ngrok) и повторите пункт 2.

:run_end
echo.
echo Агенту дайте: хост, порт, пользователь agent и приватный ключ (пункт 4).
echo Когда закончите работу, выберите пункт 3.
pause
goto menu

:err_run
echo.
echo sshd не запустился. Сначала выполните пункт 1.
pause
goto menu

rem ==========================================
:do_stop
taskkill /f /im ngrok.exe >nul 2>&1
net stop sshd >nul 2>&1
echo Туннель и sshd остановлены.
pause
goto menu

rem ==========================================
:do_showkey
cls
if not exist "%KEY%" goto no_key
echo Приватный ключ (копируйте целиком, включая строки BEGIN и END):
echo.
type "%KEY%"
echo.
pause
goto menu
:no_key
echo Ключа нет. Сначала выполните пункт 1.
pause
goto menu

rem ==========================================
:do_remove
cls
echo Будут удалены: пользователь agent, ключи, настройки sshd от этого bat.
choice /c YN /n /m "Продолжить? (Y/N): "
if errorlevel 2 goto menu
taskkill /f /im ngrok.exe >nul 2>&1
net stop sshd >nul 2>&1
powershell -NoProfile -Command "$f=Join-Path $env:ProgramData 'ssh\sshd_config'; if (Test-Path $f) { $t=Get-Content $f -Raw; $t=[regex]::Replace($t,'(?s)# AGENT-BEGIN.*?# AGENT-END\s*',''); Set-Content -Path $f -Value $t -Encoding ascii }; if (Get-LocalUser -Name agent -ErrorAction SilentlyContinue) { Remove-LocalUser -Name agent }"
if exist "%AKF%" del /f /q "%AKF%"
if exist "%KEY%" del /f /q "%KEY%"
if exist "%KEY%.pub" del /f /q "%KEY%.pub"
echo Удалено. Права на папку проекта исчезли вместе с пользователем.
pause
goto menu
