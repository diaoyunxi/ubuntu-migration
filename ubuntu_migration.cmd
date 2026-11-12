@echo off
setlocal EnableExtensions
rem ============================================================
rem Ubuntu 迁移工具 - Windows CMD 入口（中文 + 彩色 + DEBUG 级日志）
rem 兼容 Windows 10 / 11，仅用标准 cmd 内置工具（color / chcp 等），
rem 不依赖任何外部组件。
rem 本文件以 GBK(CP936) 编码保存，并用 chcp 936 固定代码页，
rem 以便在任意 locale 下正确显示中文。
rem
rem 功能：
rem   1. 确保脚本运行于 D:\backup（必要时自拷贝并重新启动）
rem   2. 检测带盘符的非 C 盘固定磁盘
rem   3. 扫描 C:\ 中疑似用户文件，跳过系统/程序目录
rem   4. 展示文件清单，允许交互删减
rem   5. 将所选文件复制到 D:\backup\C（保留相对路径，每次都覆盖为最新，
rem      但不删除本次未选中的其他文件）
rem   6. 从注册表 + 程序目录发现已安装应用，去重后允许删减
rem   7. 为所选应用查找 apt/snap 候选包名并记录供 Bash 端使用
rem      （重扫后原地去重，保留既有/手动条目，绝不删除）
rem   8. Ubuntu ISO（幂等：目标目录已有则跳过下载，缺失才自动下载）
rem   9. 尝试创建 EFI BCD 启动项（UEFI 系统，尽力而为）
rem  10. 告知制作启动 U 盘并重启，随后在装好的系统里运行 Bash 入口
rem
rem 可重复运行：重复运行不会删除 D:\backup 里已有的备份文件，也不会
rem 重复下载已存在的 ISO；文件会每次重新复制覆盖为最新（但不删未选中的），
rem 应用候选清单去重保留既有条目。
rem ============================================================

rem ---- 固定代码页，保证中文显示 ----
chcp 936 >nul

set "BACKUP_ROOT=D:\backup"
set "BACKUP_C_DIR=%BACKUP_ROOT%\C"
set "BACKUP_APP_DIR=%BACKUP_ROOT%\app"
set "LOG_FILE=%BACKUP_ROOT%\ubuntu_migration_cmd.log"
set "SCRIPT_FILE=%~nx0"

rem ---- 日志级别（默认 DEBUG = 最详细）----
rem 可选值：DEBUG / INFO / WARN / ERROR / OFF
if defined LOG_LEVEL goto :level_set
set "LOG_LEVEL=DEBUG"
:level_set
rem 详细度阈值：OFF=0 ERROR=1 WARN=2 INFO=3 DEBUG=4
set "THRESH=4"
if /I "%LOG_LEVEL%"=="INFO"  set "THRESH=3"
if /I "%LOG_LEVEL%"=="WARN"  set "THRESH=2"
if /I "%LOG_LEVEL%"=="ERROR" set "THRESH=1"
if /I "%LOG_LEVEL%"=="OFF"   set "THRESH=0"

rem ---- 初始化日志文件 ----
if not exist "%BACKUP_ROOT%\" mkdir "%BACKUP_ROOT%" 2>nul
> "%LOG_FILE%" 2>nul echo ============================================================
echo  Ubuntu 迁移工具 - Windows CMD 入口 >> "%LOG_FILE%"
echo  日志级别: %LOG_LEVEL%  (阈值=%THRESH%) >> "%LOG_FILE%"
echo  启动时间: %date% %time% >> "%LOG_FILE%"
echo ============================================================ >> "%LOG_FILE%"

color 7 >nul 2>nul
call :lg_step [1/10] 正在确保备份根目录 %BACKUP_ROOT% 存在...
if not exist "%BACKUP_ROOT%\" (
    call :lg_dbg 目录不存在，正在创建 %BACKUP_ROOT%
    mkdir "%BACKUP_ROOT%" || goto :error
)
call :lg_info 备份根目录就绪: %BACKUP_ROOT%

rem -------------------------------------------------------
rem 若尚未运行于 D:\backup，则自拷贝并重启动
rem -------------------------------------------------------
if /I NOT "%~dp0"=="%BACKUP_ROOT%\" (
    call :lg_warn 本工具必须在 %BACKUP_ROOT% 下运行。
    call :lg_warn 正在将 %SCRIPT_FILE% 拷贝到 %BACKUP_ROOT% 并重新启动...
    copy /Y "%~f0" "%BACKUP_ROOT%\%SCRIPT_FILE%" || goto :error
    start "" cmd /C ""%BACKUP_ROOT%\%SCRIPT_FILE%" && pause"
    exit /b 0
)
call :lg_dbg 脚本位于 %~dp0 ，无需重启动

call :lg_step [2/10] 正在检测非系统固定磁盘...
set "EXTRA_DRIVES="
rem wmic 在新版 Windows 可能已弃用；先尝试它，再回退
where wmic >nul 2>nul
call :lg_dbg 检查 wmic 是否可用（用于枚举磁盘）
if %errorlevel%==0 (
    for /f "tokens=1" %%d in ('wmic logicaldisk where "DriveType=3" get Name 2^>nul') do (
        if not "%%~d"=="" if /I not "%%~d"=="Name" call :add_extra_drive %%~d
    )
    call :lg_dbg 已通过 wmic 枚举固定磁盘
) else (
    call :lg_dbg wmic 不可用，回退到逐盘符探测
    for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
        if exist "%%d:\" call :add_extra_drive %%d:
    )
)
if defined EXTRA_DRIVES (
    call :lg_info 检测到非 C 盘固定磁盘: %EXTRA_DRIVES%
) else (
    call :lg_warn 未检测到额外的固定磁盘（除 C/D 外）。
)

call :lg_step [3/10] 正在扫描 C:\ 中的疑似用户文件...
set "SEL_FILE_LIST=%TEMP%\ubuntu_sel_files.txt"
set "ALL_FILE_LIST=%TEMP%\ubuntu_all_files.txt"
del "%SEL_FILE_LIST%" 2>nul
del "%ALL_FILE_LIST%" 2>nul
set /a FILE_COUNT=0
call :lg_dbg 候选文件清单: %ALL_FILE_LIST%
call :lg_dbg 选中文件清单: %SEL_FILE_LIST%

if exist "C:\Users" (
    rem 逐个迭代 C:\Users 下的真实用户目录（必须带通配符 \*，否则
    rem for /d 会把 "C:\Users" 当作单个字面目录只迭代一次、扫不到文件）。
    for /d %%u in ("C:\Users\*") do (
        call :scan_user "%%~nxu"
    )
)
if exist "C:\Documents and Settings" (
    for /d %%u in ("C:\Documents and Settings") do (
        if exist "%%~u\My Documents" for /r "%%~u\My Documents" %%f in (*) do call :scan_file "%%f"
        if exist "%%~u\My Music" for /r "%%~u\My Music" %%f in (*) do call :scan_file "%%f"
        if exist "%%~u\My Pictures" for /r "%%~u\My Pictures" %%f in (*) do call :scan_file "%%f"
    )
)
for %%f in ("C:\*.*") do call :scan_file "%%f"

call :lg_info 发现候选用户文件数: %FILE_COUNT%
if %FILE_COUNT% gtr 0 (
    call :lg_dbg 清单已保存到: %ALL_FILE_LIST%
) else (
    call :lg_warn 未发现任何候选用户文件。
)

call :lg_step [4/10] 复制前请确认文件清单（每次都覆盖为最新，不删除未选中的其他文件）。
if exist "%ALL_FILE_LIST%" call :review_file_list
if not defined FILE_SELECTED set "FILE_SELECTED=0"

color 7 >nul 2>nul
set /p "FILE_CONT=是否将所选文件复制到 %BACKUP_C_DIR%? [Y/n] "
if /I not "%FILE_CONT%"=="N" (
    if %FILE_SELECTED% gtr 0 (
        mkdir "%BACKUP_C_DIR%" 2>nul
        rem 每次都重新复制并覆盖（copy /Y），让备份目录里的文件永远最新；
        rem 但绝不删除本次未选中的其他文件。
        call :lg_dbg 开始复制 %FILE_SELECTED% 个文件到 %BACKUP_C_DIR%（每次都覆盖为最新）
        setlocal EnableDelayedExpansion
        set /a COPY_OK=0
        set /a COPY_EXIST=0
        set /a COPY_NEW=0
        set /a COPY_FAIL=0
        for /f "usebackq delims=" %%i in ("%SEL_FILE_LIST%") do (
            set "rel=%%i"
            set "rel=!rel:C:\=!"
            set "tgt=%BACKUP_C_DIR%\!rel!"
            for %%p in ("!tgt!") do set "parent=%%~dpp"
            if not exist "!parent!" mkdir "!parent!" 2>nul
            rem 先记录目标是否已存在（仅用于日志区分 覆盖/新增，copy 一律执行）
            if exist "!tgt!" (set "wasExist=1") else (set "wasExist=0")
            copy /Y "%%i" "!tgt!" >nul
            if errorlevel 1 (
                call :lg_dbg 复制失败: %%i
                set /a COPY_FAIL+=1
            ) else (
                set /a COPY_OK+=1
                if "!wasExist!"=="1" (
                    set /a COPY_EXIST+=1
                    call :lg_dbg 已覆盖旧备份: %%i
                ) else (
                    set /a COPY_NEW+=1
                    call :lg_dbg 新增文件: %%i
                )
            )
        )
        call :lg_info 文件复制完成: 成功 !COPY_OK!（其中覆盖旧备份 !COPY_EXIST!，新增 !COPY_NEW!），失败 !COPY_FAIL!
        endlocal
    ) else (
        call :lg_warn 文件数为 0，跳过复制。
    )
) else (
    call :lg_warn 用户选择跳过文件复制。
)

:apps
call :lg_step [5/10] 正在检测已安装的应用程序...
set "APP_LIST=%TEMP%\ubuntu_apps.txt"
del "%APP_LIST%" 2>nul
set /a APP_COUNT=0
call :lg_dbg 应用清单文件: %APP_LIST%

for /f "usebackq tokens=*" %%k in ('reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" /f 2^>nul') do (
    call :reg_subkey "%%k" "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
)
for /f "usebackq tokens=*" %%k in ('reg query "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" /f 2^>nul') do (
    call :reg_subkey "%%k" "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)
for /f "usebackq tokens=*" %%k in ('reg query "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" /f 2^>nul') do (
    call :reg_subkey "%%k" "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
)

if exist "C:\Program Files" for /d %%d in ("C:\Program Files\*") do (
    call :lg_dbg 发现程序目录: %%~nxd
    echo %%~nxd >> "%APP_LIST%"
    set /a APP_COUNT+=1
)
if exist "C:\Program Files (x86)" for /d %%d in ("C:\Program Files (x86)\*") do (
    call :lg_dbg 发现 32 位程序目录: %%~nxd
    echo %%~nxd >> "%APP_LIST%"
    set /a APP_COUNT+=1
)

set "APP_LIST_CLEAN=%TEMP%\ubuntu_apps_clean.txt"
del "%APP_LIST_CLEAN%" 2>nul
if exist "%APP_LIST%" (
    sort "%APP_LIST%" /unique > "%APP_LIST_CLEAN%" 2>nul
    if exist "%APP_LIST_CLEAN%" (
        move /Y "%APP_LIST_CLEAN%" "%APP_LIST%" >nul
        set /a APP_COUNT=0
        for /f "usebackq delims=" %%a in ("%APP_LIST%") do set /a APP_COUNT+=1
    )
)

call :lg_info 发现应用数: %APP_COUNT%
if exist "%APP_LIST%" (
    call :lg_dbg 清单已保存到: %APP_LIST%
) else (
    call :lg_warn 未检测到任何应用。
)

call :lg_step [6/10] 搜索包前请确认应用清单。
if exist "%APP_LIST%" call :review_app_list

color 7 >nul 2>nul
set /p "APP_CONT=是否为所选应用搜索并记录候选包? [Y/n] "
if /I not "%APP_CONT%"=="N" (
    call :lg_step [7/10] 正在为应用搜索 apt/snap 包（重扫一遍，保留既有条目，不删除）...
    mkdir "%BACKUP_APP_DIR%" 2>nul
    if exist "%APP_LIST%" (
        for /f "usebackq delims=" %%a in ("%APP_LIST%") do (
            call :search_app "%%a"
        )
    )
    rem 重扫完成后对候选清单原地去重：保留既有（含用户手动添加）条目，
    rem 只剔除完全重复的行，绝不删除任何唯一条目。
    call :dedup_list "%BACKUP_APP_DIR%\apt_candidates.txt"
    call :dedup_list "%BACKUP_APP_DIR%\snap_candidates.txt"
    call :lg_info 包候选已写入 %BACKUP_APP_DIR%（已去重）
) else (
    call :lg_warn 用户选择跳过应用包搜索。
    call :lg_step [7/10] 已跳过。
)

:iso
call :lg_step [8/10] Ubuntu ISO（已存在则跳过，缺失才下载）...
set "UBU_ISO="
rem 幂等：若目标目录已有 ISO（优先 ubuntu-lts.iso，其次最近修改的 *.iso），
rem 则直接复用、绝不重新下载；仅当完全没有 ISO 时才自动下载。
if exist "%BACKUP_ROOT%\ubuntu-lts.iso" set "UBU_ISO=%BACKUP_ROOT%\ubuntu-lts.iso"
if not defined UBU_ISO for /f "delims=" %%F in ('dir /b /o-d "%BACKUP_ROOT%\*.iso" 2^>nul') do if not defined UBU_ISO set "UBU_ISO=%BACKUP_ROOT%\%%F"
if defined UBU_ISO (
    call :lg_info 检测到已存在的 ISO，跳过下载: %UBU_ISO%
    for %%F in ("%UBU_ISO%") do (
        call :lg_dbg ISO 大小: %%~zF 字节
    )
    echo %UBU_ISO% | findstr /i /c:"desktop" >nul 2>nul
    if errorlevel 1 (
        call :lg_warn 该文件名不含 'desktop'；若是 live-server 镜像则默认无图形桌面，
        call :lg_warn 还原脚本仍可工作，但需另行安装桌面环境。
    )
) else (
    call :lg_warn 未在 %BACKUP_ROOT% 找到 ISO，开始自动下载...
    call :download_iso
    rem 下载子程序若成功会把 UBU_ISO 回填为下载路径
    if defined UBU_ISO (
        call :lg_info 下载完成: %UBU_ISO%
    ) else (
        call :lg_warn 自动下载未成功；请手动从官方页面下载并放入 %BACKUP_ROOT%:
        echo      https://releases.ubuntu.com/24.04/
        echo    建议使用桌面版镜像；服务器版无图形界面。
    )
)

call :lg_step [9/10] 正在添加 EFI BCD 启动项（仅限 UEFI 系统，尽力而为）...
bcdedit /version >nul 2>nul
call :lg_dbg 检查 bcdedit 是否可用
if errorlevel 1 goto :bcd_skip
set "NEW_BOOT="
call :parse_bcd_create
if not defined NEW_BOOT goto :bcd_fail
bcdedit /set %NEW_BOOT% device partition=C: 2>nul
bcdedit /set %NEW_BOOT% path \EFI\Microsoft\Boot\bootmgfw.efi 2>nul
bcdedit /displayorder %NEW_BOOT% >nul 2>nul
bcdedit /displayorder %NEW_BOOT% /addfirst >nul 2>nul
call :lg_info 已创建 EFI BCD 启动项: %NEW_BOOT%
color 7 >nul 2>nul
echo    注意: 多数 UEFI 固件不会直接从本地磁盘启动 ISO 文件。
echo    上面的 BCD 项仅供参考。实际启动 Ubuntu 请:
echo      1. 用 Rufus (https://rufus.ie) 将 ISO 写入 U 盘。
echo      2. 重启，打开固件启动菜单 (F12 / Esc / F8)，选择 U 盘。
goto :bcd_done
:bcd_fail
color 7 >nul 2>nul
call :lg_warn 无法创建 BCD 项（非管理员或 bcdedit 拒绝）。
echo    这不会致命，请改用 Rufus 制作启动 U 盘。
goto :bcd_done
:bcd_skip
color 7 >nul 2>nul
call :lg_warn bcdedit 不可用（BIOS 模式或未以管理员运行）；已跳过。
echo    这并非致命错误，仍可通过 U 盘使用 ISO 文件。
:bcd_done

call :lg_step [10/10] 总结与后续步骤
echo    备份根目录:   %BACKUP_ROOT%
echo    用户文件:     %BACKUP_C_DIR%
echo    应用包:       %BACKUP_APP_DIR%
if defined UBU_ISO (
    echo    Ubuntu ISO:   %UBU_ISO%（已就绪，跳过下载）
) else (
    echo    Ubuntu ISO:   （尚未找到 - 见 [8/10]）
)
echo.
echo  后续步骤:
echo    1. 若 %BACKUP_ROOT% 里已有 Ubuntu ISO（见 [8/10]），可直接用 Rufus /
echo       balenaEtcher 制作启动 U 盘；若本次已自动下载则无需再操作。
echo    2. 重启并从 U 盘启动进入 Ubuntu 安装器。
echo    3. 安装 Ubuntu。首次进入装好的系统后，打开终端执行:
echo           bash ubuntu_migration_bash.sh
echo       它会自动判断“安装器/已安装”状态、挂载旧 Windows 盘、
echo       还原文件，并从 %BACKUP_APP_DIR% 安装软件包。
echo.
echo 详细日志已写入: %LOG_FILE%
color 7 >nul 2>nul
set /p "FINISH=按 ENTER 键退出..."
endlocal
exit /b 0

rem ============================================================
rem 日志子程序（控制台彩色 + 同步追加到 LOG_FILE 纯文本）
rem 颜色码: 调试=9 信息=A 警告=E 错误=C 步骤=B 默认=7
rem ============================================================
rem 说明: 各 helper 用 %%* 透传整条消息；color 仅切换该条控制台颜色，
rem 追加到日志文件的行始终是纯文本（不带任何转义序列）。
:lg_dbg
if %THRESH% lss 4 goto :eof
color 9 >nul 2>nul
echo    [调试] %*
echo [调试] %*>> "%LOG_FILE%"
goto :eof
:lg_info
if %THRESH% lss 3 goto :eof
color A >nul 2>nul
echo    [信息] %*
echo [信息] %*>> "%LOG_FILE%"
goto :eof
:lg_warn
if %THRESH% lss 2 goto :eof
color E >nul 2>nul
echo    [警告] %*
echo [警告] %*>> "%LOG_FILE%"
goto :eof
:lg_err
color C >nul 2>nul
echo    [错误] %*
echo [错误] %*>> "%LOG_FILE%"
goto :eof
:lg_step
color B >nul 2>nul
echo.
echo [步骤] %*
echo [步骤] %*>> "%LOG_FILE%"
goto :eof

rem ----------------------------------------------------------------
rem :scan_file <path>
rem 若路径看起来像用户数据则保留，否则跳过应用/私有目录。
rem ----------------------------------------------------------------
:scan_file
rem 纯批处理判断（零管道），免疫路径中 %% & | < > 等元字符，
rem 且省去 48935×3 次 findstr.exe 进程启动，大幅提速。
set "f=%~1"
rem --- 排除检查：若 %f% 含以下任一子串则跳过 ---
set "t=%f:\AppData\Local\Temp=X%"
if not "%t%"=="%f%" goto :eof
set "t=%f:\AppData\Local\Packages=X%"
if not "%t%"=="%f%" goto :eof
set "t=%f:\Program Files\=X%"
if not "%t%"=="%f%" goto :eof
set "t=%f:\Program Files (x86)\=X%"
if not "%t%"=="%f%" goto :eof
set "t=%f:\Windows\=X%"
if not "%t%"=="%f%" goto :eof
set "t=%f:\WinSxS\=X%"
if not "%t%"=="%f%" goto :eof
set "t=%f:\PerfLogs\=X%"
if not "%t%"=="%f%" goto :eof
set "t=%f:\Recovery\=X%"
if not "%t%"=="%f%" goto :eof
set "t=%f:\ProgramData\=X%"
if not "%t%"=="%f%" goto :eof
set "t=%f:\MSAppData\=X%"
if not "%t%"=="%f%" goto :eof
set "t=%f:\$Recycle.Bin=X%"
if not "%t%"=="%f%" goto :eof
set "t=%f:\pagefile.sys=X%"
if not "%t%"=="%f%" goto :eof
set "t=%f:\hiberfil.sys=X%"
if not "%t%"=="%f%" goto :eof
set "t=%f:\swapfile.sys=X%"
if not "%t%"=="%f%" goto :eof
set "t=%f:\SystemData=X%"
if not "%t%"=="%f%" goto :eof
set "t=%f:\inetpub\=X%"
if not "%t%"=="%f%" goto :eof
set "t=%f:\$WINDOWS.~BT=X%"
if not "%t%"=="%f%" goto :eof
set "t=%f:\winre\=X%"
if not "%t%"=="%f%" goto :eof
set "t=%f:\Boot\=X%"
if not "%t%"=="%f%" goto :eof
rem --- 扩展名检查：须有 1-8 位扩展名 ---
set "ext=%~x1"
if "%ext%"=="" goto :eof
set "ext=%ext:~1%"
if "%ext%"=="" goto :eof
if "%ext:~8,1%" neq "" goto :eof
rem --- 全部通过 → 写入清单 ---
call :lg_dbg 命中用户文件: %f%
>> "%SEL_FILE_LIST%" echo %f%
>> "%ALL_FILE_LIST%" echo %f%
set /a FILE_COUNT+=1
goto :eof

rem ----------------------------------------------------------------
rem :scan_user <username>
rem 扫描单个真实用户配置文件目录。
rem ----------------------------------------------------------------
:scan_user
set "user=%~1"
if /I "%user%"=="All Users" goto :eof
if /I "%user%"=="Default" goto :eof
if /I "%user%"=="Default User" goto :eof
if /I "%user%"=="Public" goto :eof
if /I "%user%"=="desktop.ini" goto :eof
call :lg_dbg 扫描用户: %user%
rem 只扫用户目录顶层散落文件（不递归 AppData，避免大量 exe/缓存垃圾）
for %%f in ("C:\Users\%user%\*.*") do call :scan_file "%%f"
rem 仅递归扫描 6 个个人数据目录
rem 用 dir /s /b 一次性扁平列举 + 整块重定向到临时文件再 type 追加：
rem   - 规避 for /r + call 在 52k+ 文件时触发的 BATCH RECURSION 栈溢出
rem     （Recursion Count=335 会导致整段扫描被中止、一个文件都留不下）
rem   - 整块 >> 临时文件后仅 2 次 type 追加，避免逐行 >> 的文件开销
rem 循环体内 %%~xf 判断扩展名，零 call、零递归、零额外进程。
set "TMPMATCH=%TEMP%\ubuntu_6dir_%user%.txt"
del "%TMPMATCH%" 2>nul
for %%s in (Desktop Downloads Documents Pictures Music Videos) do (
    if exist "C:\Users\%user%\%%s" (
        call :lg_dbg 目录存在: C:\Users\%user%\%%s
        (
            for /f "delims=" %%f in ('dir /s /b /a:-d "C:\Users\%user%\%%s" 2^>nul') do (
                if "%%~xf" neq "" echo %%f
            )
        ) >> "%TMPMATCH%" 2>nul
    )
)
if exist "%TMPMATCH%" (
    type "%TMPMATCH%" >> "%SEL_FILE_LIST%" 2>nul
    type "%TMPMATCH%" >> "%ALL_FILE_LIST%" 2>nul
    for /f "tokens=3" %%c in ('find /c /v "" "%TMPMATCH%" 2^>nul') do set /a FILE_COUNT+=%%c
)
del "%TMPMATCH%" 2>nul
goto :eof

rem ----------------------------------------------------------------
rem :add_extra_drive <driveletter:>
rem 若尚未存在则追加盘符到 EXTRA_DRIVES。
rem ----------------------------------------------------------------
:add_extra_drive
set "drv=%~1"
set "drv=%drv: =%"
if /I not "%drv%"=="C:" if /I not "%drv%"=="D:" (
    echo " %EXTRA_DRIVES% " | findstr /i /c:" %drv% " >nul 2>nul
    if errorlevel 1 set "EXTRA_DRIVES=%EXTRA_DRIVES% %drv%"
)
goto :eof

rem ----------------------------------------------------------------
rem :reg_subkey <rawline> <prefix>
rem 解析 reg query 输出行，若存在 DisplayName 则追加。
rem ----------------------------------------------------------------
:reg_subkey
set "line=%~1"
if /I not "%line:~0,5%"=="HKEY_" goto :eof
for /f "usebackq tokens=2,*" %%a in ('reg query "%line%" /v DisplayName 2^>nul') do (
    if not "%%a"=="" if /I "%%a:~0,4"=="REG_" if not "%%~b"=="" (
        call :lg_dbg 注册表应用: %%~b
        echo %%~b >> "%APP_LIST%"
        set /a APP_COUNT+=1
    )
)
goto :eof

rem ----------------------------------------------------------------
rem :review_file_list
rem 交互审阅候选用户文件清单。
rem ----------------------------------------------------------------
:review_file_list
set "FILE_LIST_EDITED=%TEMP%\ubuntu_sel_files_edited.txt"
call :show_and_edit "%ALL_FILE_LIST%" "%FILE_LIST_EDITED%"
move /Y "%FILE_LIST_EDITED%" "%SEL_FILE_LIST%" >nul
set /a FILE_SELECTED=0
if exist "%SEL_FILE_LIST%" (
    for /f "usebackq delims=" %%a in ("%SEL_FILE_LIST%") do set /a FILE_SELECTED+=1
)
call :lg_info 已选择 %FILE_SELECTED% 个文件用于备份。
goto :eof

rem ----------------------------------------------------------------
rem :review_app_list
rem 交互审阅候选应用清单。
rem ----------------------------------------------------------------
:review_app_list
set "APP_LIST_EDITED=%TEMP%\ubuntu_apps_edited.txt"
call :show_and_edit "%APP_LIST%" "%APP_LIST_EDITED%"
move /Y "%APP_LIST_EDITED%" "%APP_LIST%" >nul
goto :eof

rem ----------------------------------------------------------------
rem :show_and_edit <listfile> <outfile>
rem 分页展示清单并允许用记事本删除不需要的行。
rem ----------------------------------------------------------------
:show_and_edit
set "listf=%~1"
set "outf=%~2"
if /I not "%listf%"=="%outf%" copy /Y "%listf%" "%outf%" >nul
echo.
color 7 >nul 2>nul
echo    下方展示清单。你可以:
echo      - 按 E 用记事本打开并删除“不需要”备份/搜索的行，然后保存关闭;
echo      - 按 ENTER 保持全部条目不变。
set "edit_choice="
set /p "edit_choice=是否用记事本打开清单以删减? [E/n] "
if /I "%edit_choice%"=="E" (
    start /wait notepad "%outf%"
)
goto :eof

rem ----------------------------------------------------------------
rem :search_app <appname>
rem 为 Windows 应用记录 apt/snap 候选包名供 Bash 端后续安装。
rem ----------------------------------------------------------------
:search_app
set "app=%~1"
color 7 >nul 2>nul
echo  应用: %app%
set "slug=%app%"
set "slug=%slug:\=_%"
set "slug=%slug:/=_%"
set "slug=%slug: =_%"
set "slug=%slug:&=_%"
set "slug=%slug:+=_%"
set "slug=%slug:(=_%"
set "slug=%slug:)=_%"
set "slug=%slug:A=a%"
set "slug=%slug:B=b%"
set "slug=%slug:C=c%"
set "slug=%slug:D=d%"
set "slug=%slug:E=e%"
set "slug=%slug:F=f%"
set "slug=%slug:G=g%"
set "slug=%slug:H=h%"
set "slug=%slug:I=i%"
set "slug=%slug:J=j%"
set "slug=%slug:K=k%"
set "slug=%slug:L=l%"
set "slug=%slug:M=m%"
set "slug=%slug:N=n%"
set "slug=%slug:O=o%"
set "slug=%slug:P=p%"
set "slug=%slug:Q=q%"
set "slug=%slug:R=r%"
set "slug=%slug:S=s%"
set "slug=%slug:T=t%"
set "slug=%slug:U=u%"
set "slug=%slug:V=v%"
set "slug=%slug:W=w%"
set "slug=%slug:X=x%"
set "slug=%slug:Y=y%"
set "slug=%slug:Z=z%"
call :lg_dbg 生成 apt slug: %slug%
color 7 >nul 2>nul
echo    apt 候选: %slug%
>> "%BACKUP_APP_DIR%\apt_candidates.txt" echo %slug%
set "slug_orig=%app%"
set "slug_orig=%slug_orig:\=_%"
set "slug_orig=%slug_orig:/=_%"
set "slug_orig=%slug_orig: =_%"
set "slug_orig=%slug_orig:&=_%"
set "slug_orig=%slug_orig:+=_%"
set "slug_orig=%slug_orig:(=_%"
set "slug_orig=%slug_orig:)=_%"
call :lg_dbg 生成 snap slug: %slug_orig%
echo    snap 候选: %slug_orig%
>> "%BACKUP_APP_DIR%\snap_candidates.txt" echo %slug_orig%
call :try_known_app_mapping "%app%"
goto :eof

rem ----------------------------------------------------------------
rem :try_known_app_mapping <appname>
rem 将常见 Windows 应用映射到 Ubuntu 包名。
rem ----------------------------------------------------------------
:try_known_app_mapping
set "name=%~1"
set "mapped=0"
echo %name% | findstr /i /C:"Google Chrome" >nul 2>nul && (
    call :lg_dbg 命中内置映射: Google Chrome -^> google-chrome-stable
    echo    apt 已知: google-chrome-stable
    >> "%BACKUP_APP_DIR%\apt_candidates.txt" echo google-chrome-stable
    set "mapped=1"
)
echo %name% | findstr /i /C:"Visual Studio Code" >nul 2>nul && (
    call :lg_dbg 命中内置映射: Visual Studio Code -^> code
    echo    apt 已知: code
    >> "%BACKUP_APP_DIR%\apt_candidates.txt" echo code
    set "mapped=1"
)
echo %name% | findstr /i /C:"Zoom" >nul 2>nul && (
    call :lg_dbg 命中内置映射: Zoom -^> zoom
    echo    snap 已知: zoom
    >> "%BACKUP_APP_DIR%\snap_candidates.txt" echo zoom
    set "mapped=1"
)
echo %name% | findstr /i /C:"WeChat" >nul 2>nul && (
    call :lg_dbg 命中内置映射: WeChat -^> wechat
    echo    snap 已知: wechat
    >> "%BACKUP_APP_DIR%\snap_candidates.txt" echo wechat
    set "mapped=1"
)
echo %name% | findstr /i /C:"Firefox" >nul 2>nul && (
    call :lg_dbg 命中内置映射: Firefox -^> firefox
    echo    apt 已知: firefox
    >> "%BACKUP_APP_DIR%\apt_candidates.txt" echo firefox
    set "mapped=1"
)
echo %name% | findstr /i /C:"LibreOffice" >nul 2>nul && (
    call :lg_dbg 命中内置映射: LibreOffice -^> libreoffice
    echo    apt 已知: libreoffice
    >> "%BACKUP_APP_DIR%\apt_candidates.txt" echo libreoffice
    set "mapped=1"
)
echo %name% | findstr /i /C:"VLC" >nul 2>nul && (
    call :lg_dbg 命中内置映射: VLC -^> vlc
    echo    apt 已知: vlc
    >> "%BACKUP_APP_DIR%\apt_candidates.txt" echo vlc
    set "mapped=1"
)
if "%mapped%"=="1" goto :eof
call :lg_dbg 未命中内置映射，保留 slug 由用户/Bash 端决定
goto :eof

rem ----------------------------------------------------------------
rem :parse_bcd_create
rem 运行 bcdedit /create 并解析出新项 GUID 到 NEW_BOOT。
rem ----------------------------------------------------------------
:parse_bcd_create
setlocal EnableDelayedExpansion
set "NEW_BOOT="
for /f "usebackq tokens=*" %%l in ('bcdedit /create /d "Ubuntu ISO" 2^>nul') do (
    call :bcp_parse_one "%%l"
)
endlocal & set "NEW_BOOT=%NEW_BOOT%"
goto :eof

:bcp_parse_one
for %%t in (%~1) do (
    set "tok=%%~t"
    if "!tok:~0,1!"=="{" if "!tok:~-1!"=="}" (
        set "guid=!tok:~1!"
        set "guid=!guid:~0,-1!"
        if not "!guid!"=="" set "NEW_BOOT={!guid!}"
    )
)
goto :eof

rem ----------------------------------------------------------------
rem :download_iso
rem 自动下载当前 Ubuntu LTS 桌面 ISO 到 %BACKUP_ROOT%\ubuntu-lts.iso。
rem 幂等：调用方已确认目标无 ISO；若存在 0 字节残留则先删除；
rem 使用 curl -C - 断点续传 + --fail + 3 级回退（24.04.5.1→24.04.4→历史裸名）。
rem 成功后把 UBU_ISO 回填为下载路径（call 共享环境，无需 setlocal）。
rem ----------------------------------------------------------------
:download_iso
set "ISO_OUT=%BACKUP_ROOT%\ubuntu-lts.iso"
rem 清理 0 字节残留，避免 -C - 误判为已完成
if exist "%ISO_OUT%" (
    for %%F in ("%ISO_OUT%") do if %%~zF==0 del "%ISO_OUT%" 2>nul
)
where curl >nul 2>nul
if errorlevel 1 (
    call :lg_warn 未找到 curl，无法自动下载；请手动从官方页面下载并放入 %BACKUP_ROOT%:
    echo    https://releases.ubuntu.com/24.04/
    goto :eof
)
set "DL_OK=0"
call :lg_dbg 正在下载 ISO（24.04.5.1，断点续传）...
curl -L --fail -C - --retry 3 -o "%ISO_OUT%" "https://releases.ubuntu.com/24.04/ubuntu-24.04.5.1-desktop-amd64.iso"
if not errorlevel 1 set "DL_OK=1"
if "1"=="%DL_OK%" goto :dl_done
call :lg_dbg 回退下载: 24.04.4
curl -L --fail -C - --retry 3 -o "%ISO_OUT%" "https://releases.ubuntu.com/24.04/ubuntu-24.04.4-desktop-amd64.iso"
if not errorlevel 1 set "DL_OK=1"
if "1"=="%DL_OK%" goto :dl_done
call :lg_dbg 回退下载: 历史裸名
curl -L --fail -C - --retry 3 -o "%ISO_OUT%" "https://releases.ubuntu.com/24.04/ubuntu-24.04-desktop-amd64.iso"
if not errorlevel 1 set "DL_OK=1"
:dl_done
if "1"=="%DL_OK%" (
    set "UBU_ISO=%ISO_OUT%"
    for %%F in ("%ISO_OUT%") do call :lg_dbg 已下载: %ISO_OUT%（%%~zF 字节）
    call :lg_info 自动下载完成: %ISO_OUT%
) else (
    call :lg_warn 自动下载未成功（网络或链接问题）；请手动从官方页面下载并放入 %BACKUP_ROOT%:
    echo    https://releases.ubuntu.com/24.04/
)
goto :eof

rem ----------------------------------------------------------------
rem :dedup_list <listfile>
rem 对候选清单原地去重：保留每个条目的首次出现顺序，仅剔除
rem 完全重复的行。绝不删除任何唯一条目（含用户手动添加者）。
rem 文件不存在时直接返回（不创建、不删除）。
rem ----------------------------------------------------------------
:dedup_list
set "dlf=%~1"
if not exist "%dlf%" goto :eof
set "dlc=%TEMP%\ubuntu_dedup_out.tmp"
set "seend=%TEMP%\ubuntu_seen.tmp"
> "%seend%" 2>nul del
if exist "%dlc%" del "%dlc%"
rem 循环内 call 子程序（cmd 安全模式，避免在 for 体内使用 goto）。
for /f "usebackq delims=" %%x in ("%dlf%") do (
    call :dedup_check "%%~x"
)
if exist "%dlc%" (
    move /Y "%dlc%" "%dlf%" >nul
    call :lg_dbg 已原地去重: %dlf%
) else (
    call :lg_dbg 无需去重（清单为空或全部重复）: %dlf%
)
del "%seend%" 2>nul
del "%dlc%" 2>nul
goto :eof

rem ----------------------------------------------------------------
rem :dedup_check <line>
rem 若该行首次出现则追加到去重结果（dlc）与已见集（seend）；
rem 重复行直接丢弃。由 :dedup_list 的 for 循环逐行调用。
rem ----------------------------------------------------------------
:dedup_check
set "dlc_line=%~1"
if "%dlc_line%"=="" goto :eof
rem findstr /X /C: 整行精确匹配（字面，避免通配符/特殊字符误判）
findstr /X /C:"%dlc_line%" "%seend%" >nul 2>nul
if not errorlevel 1 goto :eof
echo %dlc_line%>> "%dlc%"
echo %dlc_line%>> "%seend%"
goto :eof

:error
color C >nul 2>nul
call :lg_err 发生错误，请查看上方日志（%LOG_FILE%）。
echo.
echo 详细日志: %LOG_FILE%
pause
endlocal
exit /b 1
